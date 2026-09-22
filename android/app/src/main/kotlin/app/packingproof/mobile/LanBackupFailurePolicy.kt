package app.packingproof.mobile

internal enum class LanBackupFailureKind(val wireValue: String) {
    CREDENTIAL_INVALID("credential_invalid"),
    OFFLINE_OR_TIMEOUT("offline_or_timeout"),
    TEMPORARY_SERVICE("temporary_service"),
    UPLOAD_EXPIRED("upload_expired"),
    VERIFICATION_FAILED("verification_failed"),
    STORAGE_UNAVAILABLE("storage_unavailable"),
    NOT_BACKUP_HOST("not_backup_host"),
    INCOMPATIBLE_VERSION("incompatible_version"),
    UNKNOWN("unknown"),
}

internal object LanBackupFailurePolicy {
    fun shouldAutoRetry(failureKind: LanBackupFailureKind): Boolean = failureKind in setOf(
        LanBackupFailureKind.OFFLINE_OR_TIMEOUT,
        LanBackupFailureKind.TEMPORARY_SERVICE,
        LanBackupFailureKind.STORAGE_UNAVAILABLE,
    )

    /**
     * 手机与 iOS 端共用同一张判定表：同一台电脑返回同样的响应，两端必须判成同一类
     * 失败，否则会出现「一端会自动恢复、另一端永远停在等待续传」。
     */
    fun classifyHttp(statusCode: Int, errorCode: String): LanBackupFailureKind = when {
        statusCode == 401 || statusCode == 403 -> LanBackupFailureKind.CREDENTIAL_INVALID
        errorCode in setOf(
            "credential_missing",
            "enrollment_required",
            "device_token_invalid",
        ) -> LanBackupFailureKind.CREDENTIAL_INVALID
        errorCode == "upload_not_found" -> LanBackupFailureKind.UPLOAD_EXPIRED
        errorCode == "sha256_mismatch" || statusCode == 422 ->
            LanBackupFailureKind.VERIFICATION_FAILED
        errorCode == "storage_unavailable" -> LanBackupFailureKind.STORAGE_UNAVAILABLE
        errorCode in setOf(
            "invalid_content_range",
            "invalid_request",
            "invalid_json",
            "backup_protocol_upgrade_required",
        ) || statusCode == 404 || statusCode == 426 ->
            LanBackupFailureKind.INCOMPATIBLE_VERSION
        statusCode == 408 -> LanBackupFailureKind.OFFLINE_OR_TIMEOUT
        statusCode in setOf(409, 425, 429) ||
            statusCode in 500..599 ||
            errorCode == "offset_mismatch" ||
            errorCode == "mobile_backup_failed" ->
            LanBackupFailureKind.TEMPORARY_SERVICE
        else -> LanBackupFailureKind.UNKNOWN
    }
}
