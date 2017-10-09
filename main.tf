provider "aws" {
  region = "us-west-2"
}

resource "aws_vpc" "default" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_internet_gateway" "default" {
  vpc_id = "${aws_vpc.default.id}"
}

resource "aws_route" "internet_access" {
  route_table_id         = "${aws_vpc.default.main_route_table_id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.default.id}"
}

resource "aws_subnet" "default" {
  vpc_id                  = "${aws_vpc.default.id}"
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
}

resource "aws_security_group" "elb" {
  name        = "airflow_elb"
  description = "ELB allowing airflow http ingress"
  vpc_id      = "${aws_vpc.default.id}"

  # HTTP access from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "default" {
  name        = "airflow_sec_group"
  description = "Used in the terraform"
  vpc_id      = "${aws_vpc.default.id}"

  # SSH access from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP access from the VPC
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds" {
  name        = "airflow_db_sec_group"
  description = "Used in the terraform"
  vpc_id      = "${aws_vpc.default.id}"

  # MySQL access from the VPC (yes, postgres has a bug sending version numbers, womp)
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_elb" "web" {
  name = "airflow-elb"

  subnets         = ["${aws_subnet.default.id}"]
  security_groups = ["${aws_security_group.elb.id}"]
  instances       = ["${aws_instance.web.id}"]

  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }
}

resource "aws_key_pair" "auth" {
  key_name   = "${var.key_name}"
  public_key = "${file(var.public_key_path)}"
}

resource "aws_subnet" "db_1" {
  vpc_id            = "${aws_vpc.default.id}"
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-west-2b"
}

resource "aws_subnet" "db_2" {
  vpc_id            = "${aws_vpc.default.id}"
  cidr_block        = "10.0.3.0/24"
  availability_zone = "us-west-2a"
}

resource "aws_db_subnet_group" "default" {
  name        = "airflow_db_subnet_group"
  description = "Our main group of subnets"
  subnet_ids  = ["${aws_subnet.db_1.id}", "${aws_subnet.db_2.id}"]
}

resource "aws_db_instance" "default" {
  depends_on             = ["aws_security_group.rds"]
  identifier             = "airflow"
  allocated_storage      = "10"
  engine                 = "mysql"
  engine_version         = "5.6.35"
  instance_class         = "db.t2.micro"
  name                   = "airflow"
  username               = "airflow"
  password               = "${var.password}"
  vpc_security_group_ids = ["${aws_security_group.rds.id}"]
  db_subnet_group_name   = "${aws_db_subnet_group.default.id}"
  skip_final_snapshot    = "true"  
}

resource "aws_instance" "web" {
  depends_on             = ["aws_db_instance.default"]
  # The connection block tells our provisioner how to
  # communicate with the resource (instance)
  connection {
    # The default username for our AMI
    user = "ubuntu"
    agent = "false"
    private_key = "${file(var.private_key_path)}"

    # The connection will use the local SSH agent for authentication.
  }

  instance_type = "t2.micro"

  # Lookup the correct AMI based on the region
  # we specified
  ami = "ami-6e1a0117"

  # The name of our SSH keypair we created above.
  key_name = "${aws_key_pair.auth.id}"

  # Our Security group to allow HTTP and SSH access
  vpc_security_group_ids = ["${aws_security_group.default.id}"]

  # We're going to launch into the same subnet as our ELB. In a production
  # environment it's more common to have a separate private subnet for
  # backend instances.
  subnet_id = "${aws_subnet.default.id}"

  provisioner "file" {
    source      = "airflow.cfg"
    destination = "/tmp/airflow.cfg"
  }

  # We run a remote provisioner on the instance after creating it.
  # In this case, we just install nginx and start it. By default,
  # this should be on port 80
  provisioner "remote-exec" {
    inline = [
      "sudo apt-get -y update",
      "sudo apt-get install -yqq --no-install-recommends python python3-dev libkrb5-dev libsasl2-dev libssl-dev libffi-dev build-essential libblas-dev liblapack-dev libpq-dev git python3-pip python3-requests apt-utils curl netcat locales libmysqlclient-dev mysql-client",
      "sudo sed -i 's/^# en_US.UTF-8 UTF-8$/en_US.UTF-8 UTF-8/g' /etc/locale.gen",
      "sudo locale-gen", 
      "sudo update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8",
      "sudo python3 -m pip install -U pip setuptools wheel",
      "sudo pip install Cython",
      "sudo pip install pytz",
      "sudo pip install pyOpenSSL",
      "sudo pip install ndg-httpsclient",
      "sudo pip install pyasn1",
      "sudo pip install eventlet",
      "sudo pip install apache-airflow[crypto,mysql,jdbc]",
      "sudo sed -i -e 's/MYSQLPASSWORDHERE/${var.password}/g' /tmp/airflow.cfg",
      "sudo sed -i -e 's/MYSQLHOSTHERE/${aws_db_instance.default.address}/g' /tmp/airflow.cfg",
#      "sudo sed -i -e 's/ELBVALUEHERE/${aws_elb.web.dns_name}/g /tmp/airflow.cfg", 
      "sudo mkdir /root/airflow",
      "sudo cp /tmp/airflow.cfg /root/airflow",
      "sudo airflow initdb",
      "sudo nohup airflow webserver &"
    ]
  }
}

