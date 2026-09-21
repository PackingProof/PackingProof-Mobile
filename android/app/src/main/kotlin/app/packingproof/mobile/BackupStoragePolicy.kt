package app.packingproof.mobile

import android.content.Context
import java.time.Duration

/**
 * 录像存储与电脑确认策略。
 *
 * 数值由 Dart 端 `lib/models/backup_storage_policy.dart` 在启动时下发，这里只负责
 * 保存与读取。[FALLBACK] 仅在下发前使用（例如开机后未打开 App 的后台清理），必须与
 * Dart 端保持一致，由 `test/backup_storage_policy_contract_test.dart` 守门。
 */
internal data class BackupStoragePolicy(
    val minimumBytes: Long,
    val warningBytes: Long,
    val targetBytes: Long,
    val attestationFreshnessMs: Long,
    val confirmationLimit: Int,
    val confirmationGraceMs: Long,
) {
    val attestationFreshness: Duration get() = Duration.ofMillis(attestationFreshnessMs)
    val confirmationGrace: Duration get() = Duration.ofMillis(confirmationGraceMs)

    companion object {
        // 仅用于下发前，必须与 Dart 端 BackupStoragePolicy 的数值一致。
        val FALLBACK = BackupStoragePolicy(
            minimumBytes = 2L * 1024 * 1024 * 1024,
            warningBytes = 3L * 1024 * 1024 * 1024,
            targetBytes = 3L * 1024 * 1024 * 1024,
            attestationFreshnessMs = 5L * 60 * 1000,
            confirmationLimit = 64,
            confirmationGraceMs = 24L * 60 * 60 * 1000,
        )
    }
}

internal object BackupStoragePolicyStore {
    private const val PREFS = "lan_backup_storage_policy"

    fun save(context: Context, request: Map<String?, Any?>) {
        val current = current(context)
        val next = BackupStoragePolicy(
            minimumBytes = (request["storageMinimumBytes"] as? Number)?.toLong()
                ?: current.minimumBytes,
            warningBytes = (request["storageWarningBytes"] as? Number)?.toLong()
                ?: current.warningBytes,
            targetBytes = (request["storageTargetBytes"] as? Number)?.toLong()
                ?: current.targetBytes,
            attestationFreshnessMs = (request["storageAttestationFreshnessMs"] as? Number)?.toLong()
                ?: current.attestationFreshnessMs,
            confirmationLimit = (request["storageConfirmationLimit"] as? Number)?.toInt()
                ?: current.confirmationLimit,
            confirmationGraceMs = (request["storageConfirmationGraceMs"] as? Number)?.toLong()
                ?: current.confirmationGraceMs,
        )
        if (next == current) return
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putLong("minimumBytes", next.minimumBytes)
            .putLong("warningBytes", next.warningBytes)
            .putLong("targetBytes", next.targetBytes)
            .putLong("attestationFreshnessMs", next.attestationFreshnessMs)
            .putInt("confirmationLimit", next.confirmationLimit)
            .putLong("confirmationGraceMs", next.confirmationGraceMs)
            .apply()
    }

    fun current(context: Context): BackupStoragePolicy {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val fallback = BackupStoragePolicy.FALLBACK
        return BackupStoragePolicy(
            minimumBytes = prefs.getLong("minimumBytes", fallback.minimumBytes),
            warningBytes = prefs.getLong("warningBytes", fallback.warningBytes),
            targetBytes = prefs.getLong("targetBytes", fallback.targetBytes),
            attestationFreshnessMs = prefs.getLong(
                "attestationFreshnessMs",
                fallback.attestationFreshnessMs,
            ),
            confirmationLimit = prefs.getInt("confirmationLimit", fallback.confirmationLimit),
            confirmationGraceMs = prefs.getLong(
                "confirmationGraceMs",
                fallback.confirmationGraceMs,
            ),
        )
    }
}
