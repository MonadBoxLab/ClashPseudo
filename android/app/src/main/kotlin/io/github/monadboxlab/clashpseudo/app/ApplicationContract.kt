// 由 contracts/application.json 生成；修改源声明后运行 tool/contracts/generate.py。
package io.github.monadboxlab.clashpseudo.app

object ApplicationContract {
    const val CONFIGURATION_TEXT_BYTES = 16777216
    const val CONFIGURATION_NAME_BYTES = 80
    const val CONFIGURATION_REVISION_MAX = 2147483647
    const val CONFIGURATION_OVERRIDE_JSON_BYTES = 134217728
    const val CONFIGURATION_PREPARATION_OPTIONS_BYTES = 16777216
    const val OPERATION_ORDINARY_TIMEOUT_MS = 120000L
    const val OPERATION_BACKUP_TIMEOUT_MS = 300000L
    const val OPERATION_UI_GRACE_MS = 5000L
    const val OPERATION_SCHEDULED_NETWORK_TIMEOUT_MS = 110000L
    const val BACKUP_ARCHIVE_BYTES = 268435456
    const val BACKUP_EXPANDED_BYTES = 268435456
    const val BACKUP_CONFIGURATIONS_JSON_BYTES = 134217728
    const val BACKUP_OVERRIDES_JSON_BYTES = 134217728
    const val BACKUP_PREFERENCES_JSON_BYTES = 1048576
    const val BACKUP_MANIFEST_BYTES = 65536
    const val BACKUP_CENTRAL_DIRECTORY_BYTES = 65536
    const val BACKUP_COLLECTION_ENTRIES = 4096
    const val BACKUP_JSON_DEPTH = 32
    const val BACKUP_JSON_NODES = 200000
    const val BACKUP_FORMAT = "clash-pseudo-backup"
    const val BACKUP_VERSION = 1
    const val BACKUP_MANIFEST_FILE = "manifest.json"
    const val BACKUP_CONFIGURATIONS_FILE = "configurations.json"
    const val BACKUP_OVERRIDES_FILE = "overrides.json"
    const val BACKUP_PREFERENCES_FILE = "preferences.json"
    const val DNS_NAME_BYTES = 1024
    const val DNS_REQUEST_BYTES = 4096
    const val DNS_RESULT_BYTES = 262144
    const val DNS_RESULT_RECORDS = 512
    const val DNS_QUERY_TIMEOUT_MS = 5000L
    const val DNS_BRIDGE_TIMEOUT_MS = 6000L
    const val CONNECTION_ACTIVE_ENTRIES = 1000
    const val CONNECTION_INACTIVE_ENTRIES = 500
    const val CONNECTION_EXTRA_DETAILS = 1
    const val CONNECTION_INACTIVE_RETENTION_MS = 900000L
    const val CONNECTION_REQUEST_BYTES = 65536
    const val CONNECTION_ROW_BYTES = 4096
    const val CONNECTION_RESPONSE_BYTES = 8388608
}
