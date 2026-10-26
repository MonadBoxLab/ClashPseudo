// 由 contracts/application.json 生成；修改源声明后运行 tool/contracts/generate.py。
package appcontract

const (
	ConfigurationTextBytes               = 16777216
	ConfigurationNameBytes               = 80
	ConfigurationRevisionMax             = 2147483647
	ConfigurationOverrideJsonBytes       = 134217728
	ConfigurationPreparationOptionsBytes = 16777216
	OperationOrdinaryTimeoutMs           = 120000
	OperationBackupTimeoutMs             = 300000
	OperationUiGraceMs                   = 5000
	OperationScheduledNetworkTimeoutMs   = 110000
	BackupArchiveBytes                   = 268435456
	BackupExpandedBytes                  = 268435456
	BackupConfigurationsJsonBytes        = 134217728
	BackupOverridesJsonBytes             = 134217728
	BackupPreferencesJsonBytes           = 1048576
	BackupManifestBytes                  = 65536
	BackupCentralDirectoryBytes          = 65536
	BackupCollectionEntries              = 4096
	BackupJsonDepth                      = 32
	BackupJsonNodes                      = 200000
	BackupFormat                         = "clash-pseudo-backup"
	BackupVersion                        = 1
	BackupManifestFile                   = "manifest.json"
	BackupConfigurationsFile             = "configurations.json"
	BackupOverridesFile                  = "overrides.json"
	BackupPreferencesFile                = "preferences.json"
	DnsNameBytes                         = 1024
	DnsRequestBytes                      = 4096
	DnsResultBytes                       = 262144
	DnsResultRecords                     = 512
	DnsQueryTimeoutMs                    = 5000
	DnsBridgeTimeoutMs                   = 6000
	ConnectionActiveEntries              = 1000
	ConnectionInactiveEntries            = 500
	ConnectionExtraDetails               = 1
	ConnectionInactiveRetentionMs        = 900000
	ConnectionRequestBytes               = 65536
	ConnectionRowBytes                   = 4096
	ConnectionResponseBytes              = 8388608
)
