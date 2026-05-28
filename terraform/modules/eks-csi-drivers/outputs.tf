output "ebs_csi_role_arn" {
  value = aws_iam_role.ebs_csi.arn
}

output "efs_csi_role_arn" {
  value = try(aws_iam_role.efs_csi[0].arn, null)
}

output "fsx_csi_role_arn" {
  value = try(aws_iam_role.fsx_csi[0].arn, null)
}

output "s3_csi_role_arn" {
  value = try(aws_iam_role.s3_csi[0].arn, null)
}
