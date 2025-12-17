terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
  
  # --- IMPORTANTE: REVISA QUE TU BUCKET SIGA BIEN AQUÍ ---
  backend "s3" {
    bucket = "andy-terraform-estado-nuevo-2025" 
    key    = "terraform/state.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

# --- 1. ECR REPOSITORIES ---
resource "aws_ecr_repository" "cms_repo" {
  name                 = "diagnosis-cms"
  force_delete         = true
}

resource "aws_ecr_repository" "web_repo" {
  name                 = "diagnosis-web"
  force_delete         = true
}

# --- 2. RED (VPC) ---
resource "aws_vpc" "main_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "diagnosis-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id
}

# CAMBIO AQUÍ: Usamos 10.0.10.0 para evitar conflictos
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.10.0/24" 
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
}

# CAMBIO AQUÍ: Usamos 10.0.20.0 para evitar conflictos
resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.20.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public_rt.id
}
resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public_rt.id
}

# --- 3. SECURITY GROUP ---
resource "aws_security_group" "web_sg" {
  name   = "diagnosis-sg-final"
  vpc_id = aws_vpc.main_vpc.id

  # Frontend
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Backend
  ingress {
    from_port   = 1337
    to_port     = 1337
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Base de Datos
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Salida
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- 4. INSTANCIA DB ---
resource "aws_instance" "db_instance" {
  ami           = "ami-0c7217cdde317cfec" 
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public_a.id
  security_groups = [aws_security_group.web_sg.id]
  
  tags = { Name = "Diagnosis-DB" }

  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y postgresql postgresql-contrib
              EOF
}

# --- 5. INSTANCIA BACKEND ---
resource "aws_instance" "backend_instance" {
  ami           = "ami-0c7217cdde317cfec"
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public_a.id
  security_groups = [aws_security_group.web_sg.id]
  
  iam_instance_profile = "LabInstanceProfile"
  
  depends_on = [aws_instance.db_instance]

  tags = { Name = "Diagnosis-Backend" }

  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y docker.io unzip
              curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              unzip awscliv2.zip
              ./aws/install
              systemctl start docker
              usermod -aG docker ubuntu
              
              aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.us-east-1.amazonaws.com
              
              docker run -d --restart always -p 1337:1337 \
                -e DB_HOST=${aws_instance.db_instance.private_ip} \
                ${data.aws_caller_identity.current.account_id}.dkr.ecr.us-east-1.amazonaws.com/diagnosis-cms:latest
              EOF
}

# --- 6. INSTANCIA FRONTEND ---
resource "aws_instance" "frontend_instance" {
  ami           = "ami-0c7217cdde317cfec"
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public_a.id
  security_groups = [aws_security_group.web_sg.id]
  
  iam_instance_profile = "LabInstanceProfile"
  
  tags = { Name = "Diagnosis-Frontend" }

  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y docker.io unzip
              curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              unzip awscliv2.zip
              ./aws/install
              systemctl start docker
              usermod -aG docker ubuntu
              
              aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.us-east-1.amazonaws.com
              
              docker run -d --restart always -p 80:80 \
                ${data.aws_caller_identity.current.account_id}.dkr.ecr.us-east-1.amazonaws.com/diagnosis-web:latest
              EOF
}

# --- 7. LOAD BALANCER ---
resource "aws_lb" "main_lb" {
  name               = "diagnosis-load-balancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

# Target Group Frontend
resource "aws_lb_target_group" "front_tg" {
  name     = "tg-frontend"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main_vpc.id
  health_check {
    matcher = "200-499"
  }
}
resource "aws_lb_target_group_attachment" "front_attach" {
  target_group_arn = aws_lb_target_group.front_tg.arn
  target_id        = aws_instance.frontend_instance.id
  port             = 80
}

# Target Group Backend
resource "aws_lb_target_group" "back_tg" {
  name     = "tg-backend"
  port     = 1337
  protocol = "HTTP"
  vpc_id   = aws_vpc.main_vpc.id
  health_check {
    matcher = "200-499"
  }
}
resource "aws_lb_target_group_attachment" "back_attach" {
  target_group_arn = aws_lb_target_group.back_tg.arn
  target_id        = aws_instance.backend_instance.id
  port             = 1337
}

# Listeners
resource "aws_lb_listener" "front_listener" {
  load_balancer_arn = aws_lb.main_lb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.front_tg.arn
  }
}

resource "aws_lb_listener" "back_listener" {
  load_balancer_arn = aws_lb.main_lb.arn
  port              = "1337"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.back_tg.arn
  }
}

# --- 8. OUTPUTS ---
output "DNS_DEL_LOAD_BALANCER" {
  value = aws_lb.main_lb.dns_name
  description = "Tu enlace final."
}