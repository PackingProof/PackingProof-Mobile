package app.packingproof.mobile

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.SocketTimeoutException
import java.net.URL
import java.util.Collections

internal class LanBackupHostResolver(private val context: Context) {
    companion object {
        private const val HTTP_PORT = 5280
        private const val UDP_PORT = 5281
        private const val MINIMUM_HOST_VERSION = "0.0.32"
        private const val BACKUP_PROTOCOL = "mobile-backup-v2"
        private const val ENROLLMENT_VERSION = 2
        private const val AUTH_VERSION = 3
    }

    suspend fun resolve(currentBaseUrl: String, expectedNodeId: String): String? =
        withContext(Dispatchers.IO) {
            val nodeId = expectedNodeId.trim()
            if (nodeId.isEmpty()) return@withContext null
            probe(currentBaseUrl, nodeId)?.let { return@withContext it }

            val candidates = linkedSetOf<String>()
            candidates += udpCandidates(nodeId)
            candidates += subnetCandidates()
            for (batch in candidates.chunked(32)) {
                val matches = coroutineScope {
                    batch.map { candidate ->
                        async(Dispatchers.IO) { probe(candidate, nodeId) }
                    }.awaitAll()
                }
                matches.firstOrNull { it != null }?.let { return@withContext it }
            }
            null
        }

    private fun probe(baseUrl: String, expectedNodeId: String): String? {
        val normalized = baseUrl.trimEnd('/')
        return runCatching {
            val connection = URL("$normalized/api/node-info").openConnection() as HttpURLConnection
            connection.connectTimeout = 700
            connection.readTimeout = 900
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            if (connection.responseCode != 200) return null
            val body = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            val node = JSONObject(body)
            if (node.optString("protocol") != "packingproof" ||
                node.optInt("protocolVersion") != 1 ||
                node.optString("nodeId").trim() != expectedNodeId ||
                !hasCapability(node, "host") ||
                !hasCapability(node, "mobile-backup") ||
                !isCompatible(node.optJSONObject("backupCompatibility"))
            ) {
                return null
            }
            val port = node.optInt("httpPort", URL(normalized).port.takeIf { it > 0 } ?: HTTP_PORT)
                .takeIf { it in 1..65535 } ?: HTTP_PORT
            val source = URL(normalized)
            "${source.protocol}://${source.host}:$port"
        }.getOrNull()
    }

    private fun hasCapability(node: JSONObject, expected: String): Boolean {
        val values = node.optJSONArray("capabilities") ?: return false
        return (0 until values.length()).any {
            values.optString(it).equals(expected, ignoreCase = true)
        }
    }

    private fun isCompatible(value: JSONObject?): Boolean {
        val compatibility = value ?: return false
        val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
        val appVersion = packageInfo.versionName.orEmpty()
        val appBuild = if (android.os.Build.VERSION.SDK_INT >= 28) {
            packageInfo.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            packageInfo.versionCode.toLong()
        }
        return compareVersions(compatibility.optString("hostVersion"), MINIMUM_HOST_VERSION) >= 0 &&
            compatibility.optString("protocol") == BACKUP_PROTOCOL &&
            compatibility.optInt("enrollmentVersion") == ENROLLMENT_VERSION &&
            compatibility.optInt("authVersion") == AUTH_VERSION &&
            compareVersions(appVersion, compatibility.optString("minimumMobileVersion")) >= 0 &&
            appBuild >= compatibility.optLong("minimumMobileBuildNumber", Long.MAX_VALUE)
    }

    private fun udpCandidates(expectedNodeId: String): List<String> {
        val result = linkedSetOf<String>()
        val request = JSONObject()
            .put("protocol", "packingproof")
            .put("protocolVersion", 1)
            .put("action", "discover")
            .toString()
            .toByteArray(Charsets.UTF_8)
        runCatching {
            DatagramSocket().use { socket ->
                socket.broadcast = true
                socket.soTimeout = 650
                socket.send(
                    DatagramPacket(
                        request,
                        request.size,
                        InetAddress.getByName("255.255.255.255"),
                        UDP_PORT,
                    ),
                )
                while (true) {
                    val bytes = ByteArray(512)
                    val packet = DatagramPacket(bytes, bytes.size)
                    try {
                        socket.receive(packet)
                    } catch (_: SocketTimeoutException) {
                        break
                    }
                    val announce = runCatching {
                        JSONObject(String(packet.data, 0, packet.length, Charsets.UTF_8))
                    }.getOrNull() ?: continue
                    if (announce.optString("protocol") != "packingproof" ||
                        announce.optInt("protocolVersion") != 1 ||
                        announce.optString("action") != "announce" ||
                        announce.optString("nodeId").trim() != expectedNodeId
                    ) {
                        continue
                    }
                    val port = announce.optInt("httpPort")
                    if (port in 1..65535) result += "http://${packet.address.hostAddress}:$port"
                }
            }
        }
        return result.toList()
    }

    private fun subnetCandidates(): List<String> {
        val localAddresses = Collections.list(NetworkInterface.getNetworkInterfaces())
            .flatMap { Collections.list(it.inetAddresses) }
            .filterIsInstance<Inet4Address>()
            .map { it.hostAddress.orEmpty() }
            .filter(::isPrivateIpv4)
            .toSet()
        val result = linkedSetOf<String>()
        localAddresses.forEach { address ->
            val parts = address.split('.')
            val prefix = parts.take(3).joinToString(".")
            scanOrder(parts[3].toInt()).forEach { host ->
                val candidate = "$prefix.$host"
                if (candidate !in localAddresses) result += "http://$candidate:$HTTP_PORT"
            }
        }
        return result.toList()
    }
}

internal fun compareLanBackupVersions(left: String, right: String): Int {
    fun parse(value: String): List<Int>? {
        val normalized = value.trim().removePrefix("v").removePrefix("V")
            .substringBefore('+').substringBefore('-')
        return normalized.split('.').map { it.toIntOrNull() ?: return null }
    }
    val leftParts = parse(left) ?: return -1
    val rightParts = parse(right) ?: return 1
    repeat(maxOf(leftParts.size, rightParts.size)) { index ->
        val comparison = leftParts.getOrElse(index) { 0 }
            .compareTo(rightParts.getOrElse(index) { 0 })
        if (comparison != 0) return comparison
    }
    return 0
}

private fun compareVersions(left: String, right: String): Int =
    compareLanBackupVersions(left, right)

private fun isPrivateIpv4(value: String): Boolean {
    val parts = value.split('.').mapNotNull(String::toIntOrNull)
    if (parts.size != 4 || parts.any { it !in 0..255 }) return false
    return parts[0] == 10 ||
        (parts[0] == 172 && parts[1] in 16..31) ||
        (parts[0] == 192 && parts[1] == 168)
}

private fun scanOrder(localHost: Int): List<Int> = buildList {
    for (low in 1..127) {
        val high = 255 - low
        if (low != localHost) add(low)
        if (high != localHost) add(high)
    }
}
