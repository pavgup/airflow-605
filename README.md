# 605.tv Airflow Setup
This is a quick set of details on how to run terraform on YOUURRR local machine! :)

# Environment Setup
1. Drop in your aws_access_key_id and aws_secret_access_key in ~/.aws/credentials
2. Make sure you've got terraform setup on your machien (https://www.terraform.io/intro/getting-started/install.html)
3. Get ready to terraform!

# Known Issues
1. Terraform isn't handling postgres correctly
2. Redis not required for LocalExecutor variation of airflow
3. ELB value is hard to pass to instance in remote-exec block, need a null resource, didn't have time

# Making this happen:
`./terraform destroy -var 'key_name=terraform' -var 'public_key_path=/Users/pavan/.ssh/id_rsa.pub' -var 'private_key_path=/Users/pavan/.ssh/id_rsa'  -var 'password=PUTSOMETHINGHERE!`
