# mobile-backup-v1

本文档约定 PackingProof-Mobile 与 ExpressPackingMonitoring 电脑端之间的录像备份和远程录像库协议。协议版本固定为 `1`。

## 连接与鉴权

手机从“手机/电脑连接”二维码取得电脑的局域网地址和访问密钥。所有 `mobile-backup-v1` 请求必须携带：

```http
X-EPM-Access-Key: <access-key>
```

- 缺少请求头返回 `401 pairing_required`
- 密钥错误返回 `403 access_key_invalid`
- `401/403` 不自动重试，立即提示用户重新配对
- 查询参数和 Cookie 不能替代此请求头

## 最小录像元数据

APP 不上传订单留言、卖家备注、商品、退款信息或手机本地文件路径。同一物理文件可以包含多段逻辑录像，完成上传时提交：

```json
{
  "fileSha256": "64 位小写十六进制 SHA256",
  "sourceDeviceId": "APP 安装实例持久 ID",
  "sourceDeviceName": "用户可识别的设备名称",
  "sessions": [
    {
      "id": "APP 本地录像持久 ID",
      "trackingNumber": "面单号，可为空",
      "startedAt": "2026-07-19T10:00:00Z",
      "endedAt": "2026-07-19T10:00:12Z",
      "mediaStartMs": 0,
      "mediaEndMs": 12345,
      "markers": []
    }
  ]
}
```

电脑端按标准化面单号关联已有订单；暂时没有订单信息时直接保存录像。后续订单推送或精确查询会补全留言、备注、商品和退款信息。

## 能力协商

`GET /api/mobile-backup/capabilities`

```json
{
  "protocol": "mobile-backup-v1",
  "version": 1,
  "computerId": "stable-computer-id",
  "computerName": "仓库电脑",
  "maxChunkBytes": 4194304,
  "supportedFormats": ["video/mp4"],
  "features": {
    "videoLibrary": true,
    "rangePlayback": true,
    "multipleSessionsPerFile": true
  },
  "retryPolicy": {
    "chunkMaxAttempts": 5,
    "chunkBackoffSeconds": [1, 2, 4, 8, 16],
    "fileMaxAttempts": 3
  }
}
```

## 创建或恢复上传

`POST /api/mobile-backup/uploads`

请求：

```json
{
  "fileSha256": "完整 MP4 文件 SHA256",
  "totalBytes": 12345678,
  "mimeType": "video/mp4"
}
```

服务端按完整文件 SHA256 幂等创建或恢复任务：

```json
{
  "uploadId": "与 fileSha256 相同",
  "offset": 0,
  "chunkSize": 4194304,
  "fileReady": false
}
```

`fileReady=true` 表示电脑已保存并校验过相同物理文件，APP 可直接调用完成接口创建当前逻辑录像记录。

## 上传分块

`PUT /api/mobile-backup/uploads/{uploadId}/chunks`

请求体为二进制数据，请求头包含：

```http
Content-Range: bytes <start>-<end>/<total>
X-Chunk-SHA256: <当前分块 SHA256>
```

成功响应：

```json
{
  "uploadId": "...",
  "offset": 4194304
}
```

- `409 offset_mismatch` 不计入失败次数，按 `expectedOffset` 继续
- 分块 SHA256 错误属于请求或文件问题，不重复消耗流量
- 超时、断网或 `5xx` 对当前分块最多尝试 5 次，等待 `1、2、4、8、16` 秒并加入少量随机抖动
- 其他 `4xx` 不自动重试

## 完成、校验与确认

`POST /api/mobile-backup/uploads/{uploadId}/complete`

请求使用“最小录像元数据”中的 JSON。电脑重新计算完整文件 SHA256，校验通过后原子保存物理文件并写入对应的录像记录，返回：

```json
{
  "status": "verified",
  "fileSha256": "...",
  "recordId": 123,
  "alreadyCompleted": false,
  "message": "电脑校验完成，备份成功"
}
```

APP 只有收到 `status=verified` 且 SHA256 与本地一致时，才显示“电脑校验完成，备份成功”。若响应丢失，使用相同 `sourceDeviceId + sessions[].id` 再次完成会返回相同录像记录，并将 `alreadyCompleted` 设为 `true`。

一个视频文件只对应一条录像记录。旧版本一次上传包含多条录像记录时，响应会额外返回 `recordIds` 数组，仅作旧数据兼容。

## 远程录像库与播放

- `GET /api/videos?page=1&pageSize=50&search=<面单号>` 分页查询电脑端全部录像
- 返回项包含 `sourceDeviceId`、`sourceSessionId`、`contentSha256`、`remote=true` 与 `playUrl`
- `GET {playUrl}` 支持标准 HTTP Range；所有请求仍需携带访问密钥
- 手机优先播放本机文件。本机文件按保留策略删除后，若电脑可用则通过 `playUrl` 播放；电脑离线时保留录像记录并明确显示暂不可播放

完整文件校验失败返回：

```json
{
  "errorCode": "sha256_mismatch",
  "expectedOffset": 0,
  "retryWholeFile": true,
  "maxFileAttempts": 3
}
```

电脑会删除错误临时文件并重置偏移。初次上传失败后最多再完整重传 2 次，即整文件总计最多尝试 3 次；仍失败则停止自动重试，提示检查网络、电脑存储空间或重新配对。

未完成任务可断点续传，超过 3 天由电脑自动清理。成功任务不长期保留上传偏移，只在录像记录中保存完整文件 SHA256。
