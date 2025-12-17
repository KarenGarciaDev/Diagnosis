terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
  
  # --- TU BUCKET DE ESTADO ---
  backend "s3" {
    bucket = "andy-terraform-estado-nuevo-2025" 
    key    = "terraform/state.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = "us-east-1"
}

# --- DATA: OBTENER ID DE LA CUENTA (Para las URLs de ECR) ---
data "aws_caller_identity" "current" {}

# --- 1. IAM ROLES (¡VITAL! Para que EC2 pueda descargar de ECR) ---
resource "aws_iam_role" "ec2_role" {
  name = "diagnosis_ec2_role_v3"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "diagnosis_ec2_profile_v3"
  role = aws_iam_role.ec2_role.name
}

# --- 2. ECR REPOSITORIES ---
resource "aws_ecr_repository" "cms_repo" {
  name                 = "diagnosis-cms"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

resource "aws_ecr_repository" "web_repo" {
  name                 = "diagnosis-web"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

# --- 3. NETWORKING (VPC) ---
resource "aws_vpc" "main_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "diagnosis-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
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
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# --- 4. SECURITY GROUP ---
resource "aws_security_group" "web_sg" {
  name   = "diagnosis-sg"
  vpc_id = aws_vpc.main_vpc.id

  # Frontend (Web)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # Backend API (Asumimos puerto 1337 o 3000, he puesto 1337)
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
  # Salida (Internet para descargar Docker)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- 5. INSTANCIA 1: BASE DE DATOS ---
resource "aws_instance" "db_instance" {
  ami           = "ami-0c7217cdde317cfec" # Ubuntu 22.04 LTS
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public_subnet.id
  security_groups = [aws_security_group.web_sg.id]
  
  tags = { Name = "Diagnosis-DB" }

  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y postgresql postgresql-contrib
              # Configuración extra de DB aquí si fuera necesaria
              EOF
}

# --- 6. INSTANCIA 2: BACKEND (CMS) ---
resource "aws_instance" "backend_instance" {
  ami           = "ami-0c7217cdde317cfec"
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public_subnet.id
  security_groups = [aws_security_group.web_sg.id]
  
  # Asignamos el perfil IAM para poder descargar de ECR
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  
  # Dependencia explicita: Esperar a que la DB exista
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
              systemctl enable docker
              usermod -aG docker ubuntu

              # Login en ECR
              aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.us-east-1.amazonaws.com

              # Correr Backend (Inyectando la IP de la Base de Datos)
              docker run -d --restart always -p 1337:1337 \
                -e DB_HOST=${aws_instance.db_instance.private_ip} \
                -e DB_PORT=5432 \
                ${data.aws_caller_identity.current.account_id}.dkr.ecr.us-east-1.amazonaws.com/diagnosis-cms:latest
              EOF
}

# --- 7. INSTANCIA 3: FRONTEND (WEB) ---
resource "aws_instance" "frontend_instance" {
  ami           = "ami-0c7217cdde317cfec"
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public_subnet.id
  security_groups = [aws_security_group.web_sg.id]
  
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  
  tags = { Name = "Diagnosis-Frontend" }

  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y docker.io unzip
              curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              unzip awscliv2.zip
              ./aws/install

              systemctl start docker
              systemctl enable docker
              usermod -aG docker ubuntu

              # Login en ECR
              aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.us-east-1.amazonaws.com

              # Correr Frontend
              docker run -d --restart always -p 80:80 \
                ${data.aws_caller_identity.current.account_id}.dkr.ecr.us-east-1.amazonaws.com/diagnosis-web:latest
              EOF
}

# --- 8. OUTPUTS (Para que sepas las IPs al terminar) ---
output "ip_frontend" {
  value = aws_instance.frontend_instance.public_ip
  description = "IP Publica para ver la pagina web"
}

output "ip_backend" {
  value = aws_instance.backend_instance.public_ip
  description = "IP Publica del Backend API"
}

output "ip_db" {
  value = aws_instance.db_instance.private_ip
  description = "IP Privada de la base de datos"
}