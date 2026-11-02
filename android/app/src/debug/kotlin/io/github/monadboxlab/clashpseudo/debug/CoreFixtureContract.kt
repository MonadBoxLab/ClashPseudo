package io.github.monadboxlab.clashpseudo.debug

/** 固定回归场景，不接受代码、反射目标或调用方路径。 */
object CoreFixtureContract {
    const val TRUST = 1
    const val BAD_REVISION = 2
    const val BAD_STACK = 3
    const val SYSTEM_INTERFACE = 4
    const val MIXED_INTERFACE = 5
    const val REFUSE_PROTECT = 6
    const val THROW_PROTECT = 7
    const val ACCEPT_PROTECT = 8
    const val CONNECTIONS = 9
    const val MODES = 10
    const val UTF8_STRATEGIES = 11
    const val FD_REUSE = 12
    const val FD_ZERO = 13
    const val GEO_MANUAL = 14
    const val GEO_AUTOMATIC = 15
    const val GEO_HOLD = 16
    const val ROUTE_PROJECTION = 17
    const val COVERAGE = 18
    const val PREPARATION_FAILURE = 19
    const val GEO_PREPARE = 20
    const val GEO_CALLBACK = 21
    const val OUTPUT_HANDOFF_FAILURE = 22
    const val TUN_HANDOFF_FAILURE = 23
    const val CAPTURE_SERVICE = 1
    const val REPLAY_RETIRED_SERVICE = 2
    const val REVOKE_SERVICE = 3
    const val CLOSE_RESOURCES = 4
    const val FOREGROUND_IO_FAILURE = 5
    const val FOREGROUND_LINKAGE_FAILURE = 6
    const val SERVICE_STATE = 7
    const val SHOW_FOREGROUND = 8
    const val STALE_SERVICE_INTENTS = 9
    const val REJECT_EXIT_EXECUTOR = 10
    const val REJECT_EXIT_LINKAGE = 11
    const val EXIT_EXECUTOR_STATE = 12
    const val REVOKE_SERVICE_OFF_MAIN = 13
}
