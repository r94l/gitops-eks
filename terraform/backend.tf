terraform {
  backend "s3" {
    bucket         = "conduit-terraform-state-2026"
    key            = "production/terraform.tfstate"
    region         = "eu-north-1"
    dynamodb_table = "fullstack-terraform-locks"
    encrypt        = true
  }
}