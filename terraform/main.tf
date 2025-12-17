terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
  
  # --- IMPORTANTE: AQUÍ PEGAS EL NOMBRE QUE CREASTE EN EL PASO 1 ---
  backend "s3" {
    bucket = "andy-terraform-estado-nuevo-2025" 
    key    = "terraform/state.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = "us-east-1"
}

# --- 1. ECR REPOSITORIES (Added specifically for your Docker script) ---
resource "aws_ecr_repository" "cms_repo" {
  name                 = "diagnosis-cms"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # Allows deleting repo even if it has images (good for testing)
}

resource "aws_ecr_repository" "web_repo" {
  name                 = "diagnosis-web"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

# --- 2. NETWORKING (VPC) ---
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

# --- 3. SECURITY GROUP ---
resource "aws_security_group" "web_sg" {
  name        = "diagnosis-sg"
  vpc_id      = aws_vpc.main_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- 4. DATABASE (PostgreSQL) ---
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
              EOF
}

# --- 5. APP SERVER (Loads Docker) ---
resource "aws_instance" "app_instance" {
  ami           = "ami-0c7217cdde317cfec"
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public_subnet.id
  security_groups = [aws_security_group.web_sg.id]
  
  tags = { Name = "Diagnosis-App" }

  # Important: This user_data installs Docker so you can pull your images later
  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y docker.io
              systemctl start docker
              systemctl enable docker
              EOF
}