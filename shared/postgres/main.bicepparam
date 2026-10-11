// Values come from .env (loaded by deploy.sh); ADMIN_GROUP_ID and ADMIN_CLIENT_IP are looked up by deploy.sh.
using 'main.bicep'

param serverName = readEnvironmentVariable('PG_INSTANCE_NAME')
param skuName = readEnvironmentVariable('PG_SKU', 'Standard_B1ms')
param adminGroupName = readEnvironmentVariable('PG_ENTRA_ADMIN_GROUP', 'pg-shared-admins')
param adminGroupObjectId = readEnvironmentVariable('ADMIN_GROUP_ID')
param pgAdminUser = readEnvironmentVariable('PG_ADMIN_USER')
param pgAdminPassword = readEnvironmentVariable('PG_ADMIN_PASSWORD')
param adminClientIp = readEnvironmentVariable('ADMIN_CLIENT_IP')
param budgetAlertEmails = readEnvironmentVariable('BUDGET_ALERT_EMAILS')
param backupRetentionDays = int(readEnvironmentVariable('PG_BACKUP_RETENTION_DAYS', '14'))
