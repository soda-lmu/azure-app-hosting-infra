// ADMIN_GROUP_ID is looked up by deploy.sh (from PG_ENTRA_ADMIN_GROUP).
using 'main.bicep'

param adminGroupObjectId = readEnvironmentVariable('ADMIN_GROUP_ID')
