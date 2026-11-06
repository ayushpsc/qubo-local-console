# Qubo captured API inventory and purposes

The supplied request and response captures establish **13 application API routes and 3 object storage download patterns**. They cover phone authentication, device commands, device shadow updates, camera streaming setup, recording timelines, doorbell transactions, event images, and SD-card media export. Every supplied response for these flows has HTTP status **200**.

This inventory describes the captured traffic from 23–24 October 2026, rather than the entire Qubo API. Routes are grouped by HTTP method and parameterized path; different device IDs, query values, and command values do not create additional routes. Credentials, signatures, personal data, and account and device identifiers are replaced with placeholders. Field spelling and capitalization are preserved.

## Hosts and path parameters

| Name | Value or meaning |
| --- | --- |
| Application base URL | `https://srvcapp.platform.quboworld.com:443` |
| North storage base URL | `https://north-az1-s3.cloud.airtel.in:10446` |
| South storage base URL | `https://south-az1-s3.cloud.airtel.in:10445`, referenced by S9 snapshot URLs |
| SD-media storage base URL | `https://heroiot-prod-push-pull.s3.ap-south-1.amazonaws.com` |
| `{region}` | `nz` for north storage; `sz` for south storage |
| `{sp}` | Service provider or tenant identifier, inferred from the `/sp/` namespace; constant across these captures |
| `{unit}` | Unit identifier; appears to group a home or installation |
| `{entity}` | Entity identifier used to scope a device; its precise business meaning is not shown |
| `{device}` | Device UUID |
| `{transaction}` | Doorbell transaction identifier; use the returned value as an opaque string |
| `{content}` | Content UUID within a transaction |

`S1`–`S14`, `S23`, and `S24` below refer to the application captures, and `A1`–`A4` to the original storage captures. The final section maps every label to its original file. The unnumbered filename is assigned label 1.

## Complete route list

All paths below are relative to the application base URL except rows 14–16, which use their corresponding storage base URL.

| No. | Method | Parameterized path | Purpose | Sources |
| --- | --- | --- | --- | --- |
| 1 | POST | `/sms/api/v1/sp/{sp}/user/phone/login` | Begin phone login; likely initiates delivery of an OTP | S13 |
| 2 | POST | `/sms/api/v1/sp/{sp}/user/phone/verify` | Verify the OTP and return user details and an authentication token | S14 |
| 3 | PUT | `/unit-entity-management/api/v1/sp/{sp}/units/{unit}/entities/{entity}/devices/{device}/command` | Submit a device service command; captured examples change air purifier fan mode | S2, S3 |
| 4 | PUT | `/unit-entity-management/api/v1/sp/{sp}/units/{unit}/entities/{entity}/devices/{device}/shadow/attribute` | Update a device shadow attribute; captured examples request power on | S4, S5 |
| 5 | PUT | `/roi-manager/api/v1/sp/{sp}/device/{device}/stream/rtsp` | Submit a streaming setup or control request with P2P and TURN parameters | S1 |
| 6 | POST | `/unit-entity-management/api/v1/sp/{sp}/units/{unit}/devices/rtsp/support` | Query RTSP support or start availability information for a batch of devices | S7 |
| 7 | POST | `/stream-manager/api/v3/sp/{sp}/unit/{unit}/devices/pp2p/credentials` | Obtain session credentials and server connection details for device streaming | S12 |
| 8 | GET | `/content-manager/api/v1/sp/{sp}/unit/{unit}/device/{device}/time-scrubber` | Retrieve recording metadata for a camera playback timeline | S8, S10 |
| 9 | GET | `/vms/api/v1/sp/{sp}/units/{unit}/devices/{device}` | List doorbell transactions or call history, including snapshot URLs | S9 |
| 10 | GET | `/vms/api/v1/sp/{sp}/units/{unit}/devices/{device}/transactions/{transaction}/contents/{content}` | Obtain a temporary signed download URL for a transaction content item | S6 |
| 11 | PUT | `/control-monitor/api/v1/sp/{sp}/lastEvent` | Retrieve the latest event for each device in a supplied batch | S11 |
| 12 | POST | `/push-pull/request` | Ask a camera to stage one or more SD-card MP4 files in temporary S3 storage | S23 |
| 13 | GET | `/push-pull/transaction/{transaction}` | Poll an export transaction and obtain temporary upload/download URLs | S24 |
| 14 | GET | `/ar-{region}-hero-iot-prod-vms-event/{transaction}/{content}` | Download a VMS event object; captured examples correspond to transaction snapshots | S9, A1, A2, A3 |
| 15 | GET | `/ar-{region}-hero-iot-prod-ai-event/{unit}/{device}_PRIMARY_{timestamp}.jpeg` | Download an AI event image associated with a camera detection | A4 |
| 16 | GET | `/sdCardMedia--{transaction}--/{camera-local-path}.mp4` | Stream a temporarily staged SD-card recording from Amazon S3 | S24, M1, M2 |

## Authentication and shared headers

Authenticated application requests outside phone login and verification carry these headers:

```http
App-Id: <app identifier>
Token-Type: USER
Source-Device-Id: <mobile installation identifier>
Source: IOS
User-UUID: <user UUID>
Subscriber-Key: <JWT>
```

The captured authentication mechanism uses `Subscriber-Key`, rather than an `Authorization: Bearer` header. S14 returns the `token` field, and later calls carry a JWT in `Subscriber-Key`; using that returned token as the subscriber key is the inferred login flow. Token refresh is outside the supplied captures.

The implemented console follows the local `ha-qubo-doorbell`/`qubopy` client for email login and refresh, where it sends `App-Id: com.hero.iot` and `Source: Android`. Subsequent application/data calls retain the captured native iOS identity shown above, including its 64-character app ID and `Source: IOS`, while carrying both `Authorization: Bearer <access token>` and the same access token as `Subscriber-Key`. This separation avoids applying the auth client identity to content-manager data lookups.

S13 and S14 omit `User-UUID` and `Subscriber-Key` and include `App-Type: HOME` and `Login-Device-Name`. All application requests include a cookie. Its necessity cannot be established from successful requests alone. JSON request bodies use `Content-Type: application/json`; GET requests have no body.

Storage requests use signed query parameters and carry no `Subscriber-Key`. Snapshot URLs use `X-Amz-Expires=86400` (24 hours); push-pull MP4 download URLs use `X-Amz-Expires=300` (five minutes). Other observed parameters are `X-Amz-Algorithm=AWS4-HMAC-SHA256`, `X-Amz-Date`, `X-Amz-SignedHeaders=host`, `X-Amz-Credential`, and `X-Amz-Signature`.

## Authentication APIs

### Phone login

**POST** `/sms/api/v1/sp/{sp}/user/phone/login` — **S13**

Begins phone based login. The endpoint name and subsequent OTP verification suggest that it initiates an OTP, although its response does not explicitly confirm SMS delivery.

Request:

```json
{
  "isdCode": "+91",
  "phone": "<phone number>",
  "deviceAttribute": "iPhone15,5"
}
```

Response, HTTP 200, JSON object:

```json
{"uuid": "<user UUID>"}
```

The returned UUID is supplied to verification and matches the user identity returned there.

### Phone OTP verification

**POST** `/sms/api/v1/sp/{sp}/user/phone/verify` — **S14**

Verifies the supplied OTP and returns authentication information.

Request:

```json
{
  "otp": "<OTP>",
  "phone": "<phone number>",
  "isdCode": "+91",
  "deviceAttribute": "iPhone15,5",
  "uuid": "<UUID from phone login>"
}
```

Response, HTTP 200, JSON array containing one user:

```json
[
  {
    "uuid": "<user UUID>",
    "email": "<email>",
    "name": "<name>",
    "token": "<JWT>"
  }
]
```

### Email/password login and refresh (reference client behavior)

These two routes are not part of the supplied packet captures. They are
implemented from behavior observed in a separate Qubo reference client:

- `POST /sms/api/v1/sp/{sp}/user/login?system=CS` accepts `username`, `email`, `password`, and `deviceAttribute`. The console sends `Apple iPhone15,5` for the device attribute and accepts either `accessToken` or `token` in the response.
- `POST /sms/api/v1/sp/{sp}/users/{user}/auth/refresh` accepts the current `accessToken` and `refreshToken`. The console refreshes within five minutes of JWT expiry, keeps a rotated refresh token, and retries an API request once after HTTP 401. HTTP 400/401/403 from the refresh route requires a new email/password login.

The email password and returned refresh token are held only in memory; the password is never placed in request activity logs.

## Device control APIs

### Device command

**PUT** `/unit-entity-management/api/v1/sp/{sp}/units/{unit}/entities/{entity}/devices/{device}/command` — **S2, S3**

Submits a command for a named device service. The target device also appears as a `smartAirPurifierX4` in S11. S2 sets `fanControlMode.attributes.state` to `qsense`; S3 sets it to `sleep`.

Representative request:

```json
{
  "topic": "/control/<unit>/<device>/fanControlMode",
  "payload": {
    "devices": {
      "deviceUUID": "<device>",
      "handleName": "<handle identifier>",
      "services": {
        "fanControlMode": {
          "instanceId": 0,
          "attributes": {"state": "qsense"}
        }
      }
    }
  }
}
```

`payload.devices` is an object, despite its plural name. The topic resembles a device messaging topic, but these captures do not establish the server's internal messaging protocol or explain `handleName`.

Both responses are HTTP 200 with:

```json
{"code": "SUCCESS_UM_006", "message": "SUCCESS_UM_006"}
```

This acknowledges the API request; the response contains no device state readback confirming that the physical fan changed mode.

### Device shadow attribute update

**PUT** `/unit-entity-management/api/v1/sp/{sp}/units/{unit}/entities/{entity}/devices/{device}/shadow/attribute` — **S4, S5**

Updates one service attribute in the device shadow. Both examples request power on:

```json
{
  "attributeName": "power",
  "attributeValue": "on",
  "instanceId": 0,
  "serviceName": "lcSwitchControl"
}
```

Both responses are HTTP 200, `text/plain;charset=UTF-8`, with body `SUCCESS`. S4 targets the air purifier from S2/S3. S5 targets a different entity and device whose product type is not identified in the supplied captures. The response acknowledges the update without returning the resulting physical device state. Other attributes and values are not demonstrated.

## Camera streaming APIs

### RTSP stream request

**PUT** `/roi-manager/api/v1/sp/{sp}/device/{device}/stream/rtsp` — **S1**

Submits a streaming setup or control request for the doorbell camera:

```json
{"transportType": "turn", "protocol": "p2p"}
```

The response is HTTP 200, `text/plain;charset=UTF-8`, with body `Ok`. Although the route contains `rtsp`, this response provides no RTSP URL, port, username, or password. Whether it starts, switches, or otherwise prepares the stream cannot be resolved from this acknowledgement alone.

### RTSP support lookup

**POST** `/unit-entity-management/api/v1/sp/{sp}/units/{unit}/devices/rtsp/support` — **S7**

Submits a batch of device model and identity information to obtain RTSP related flags.

Request:

```json
[
  {
    "deviceAModelNo": "HCD04A",
    "macAddress": "<MAC address>",
    "deviceUUID": "<device>"
  }
]
```

Response, HTTP 200:

```json
[
  {
    "macAddress": "<MAC address>",
    "deviceUUID": "<device>",
    "deviceAModelNo": "HCD04A",
    "firmwareVersion": null,
    "rtspstart": false
  }
]
```

The capture establishes only that `rtspstart` was false. It does not distinguish unsupported RTSP from RTSP being inactive or unavailable under the current conditions. The exact flag semantics remain uncertain.

### P2P streaming credentials

**POST** `/stream-manager/api/v3/sp/{sp}/unit/{unit}/devices/pp2p/credentials` — **S12**

Returns per-device streaming session data, encryption material, and a server destination. Preserve the literal route spelling `pp2p` and API version `v3`.

Request:

```json
{
  "unitUUID": "<unit>",
  "userAppID": "<mobile installation identifier>",
  "devices": [
    {"protocol": "udp", "deviceUUID": "<device>"}
  ]
}
```

Response, HTTP 200, array containing one session:

```json
[
  {
    "appSessionId": "<session ID>",
    "aesKey": "<encryption key>",
    "iv": "<initialization vector>",
    "serverIP": "<server IP>",
    "serverPort": 54869,
    "userAppId": "<mobile installation identifier>",
    "deviceUUID": "<device>",
    "protocol": "udp"
  }
]
```

The request uses `userAppID`; the response uses `userAppId`. The captured port is a returned connection value, rather than evidence of a fixed service port. The response alone does not reveal the packet format, stream handshake, encryption mode, or video transport framing needed to consume the stream.

## Recording and doorbell history APIs

### Recording timeline

**GET** `/content-manager/api/v1/sp/{sp}/unit/{unit}/device/{device}/time-scrubber` — **S8, S10**

Retrieves recording metadata for a camera timeline or time scrubber.

| Query parameter | Captured values | Interpretation |
| --- | --- | --- |
| `startTime` | `1792693800000` | Start time in Unix milliseconds; 23 October 2026 00:00:00 IST |
| `endTime` | S8: `1792780199000`; S10: `1792866599000` | End time in Unix milliseconds; respectively 23 and 24 October 2026 at 23:59:59 IST |
| `skipIntervalName` | `seconds` | Unit for the requested interval |
| `skipIntervalValue` | `30` | Requested interval value; exact filtering or sampling behavior is not established |
| `contentType` | `video` | Requested content category |

Both responses are HTTP 200 and contain the same 65 recording metadata objects, despite different end times. This does not establish that the service ignores `endTime`; there may simply be no additional matching recordings.

Representative response item:

```json
{
  "contentID": "<device>_primary_1792778167911",
  "timestamp": 1792778167911,
  "unitUUID": "<unit>",
  "deviceUUID": "<device>",
  "path": null,
  "contentEncrypted": false,
  "storageType": "sdCard",
  "lastUpdatedTimeStamp": null,
  "sourceCamera": "primary",
  "s3Path": "",
  "localPath": "/tmp/mnt/sdcard0/HERO_IOT_<sp>/Content/Recordings/<unit>/23-Oct-2026/<device>_primary_1792778167911.mp4",
  "isDeleted": null,
  "fileSize": 687,
  "endTime": 1792778200911
}
```

All 65 items report `storageType: sdCard`, `sourceCamera: primary`, and `contentEncrypted: false`. Their `localPath` is on the camera filesystem and is not a directly downloadable HTTP URL. The `fileSize` unit is not specified. These records index clips; the endpoint does not return video bytes or demonstrate how to read an SD card clip.

### Doorbell transactions

**GET** `/vms/api/v1/sp/{sp}/units/{unit}/devices/{device}` — **S9**

Lists doorbell transactions or calls for one device.

| Query parameter | Captured value | Interpretation |
| --- | --- | --- |
| `recordNumber` | `20` | Requested record count; response contains 20 entries |
| `toTimestamp` | `1792781671050` | Appears to be an upper time bound or pagination cursor in Unix milliseconds |

Response, HTTP 200, array of 20 records. Every returned record has `callStatus: MISSED`, `isRecorded: true`, and `snapshot.isSnapshotUploaded: true`.

Representative item:

```json
{
  "transactionUUID": "<transaction>",
  "deviceUUID": "<device>",
  "unitUUID": "<unit>",
  "type": null,
  "createdTimestamp": 1792737082817,
  "closedTimestamp": 1792737102903,
  "callStatus": "MISSED",
  "isRecorded": true,
  "snapshot": {
    "contentUUID": "<content>",
    "timestamp": 1792737081318,
    "downloadURL": "https://north-az1-s3.cloud.airtel.in:10446/ar-nz-hero-iot-prod-vms-event/<transaction>/<content>?<signed query>",
    "isSnapshotUploaded": true
  },
  "facesDetected": null
}
```

Of the 20 snapshot URLs in S9, **9 use north storage** with the `ar-nz-hero-iot-prod-vms-event` bucket, and **11 use south storage** with the `ar-sz-hero-iot-prod-vms-event` bucket. The north snapshot URLs connect this response directly to A1/A2/A3. `isRecorded: true` is a metadata flag; the captured record does not itself contain a recording download URL. Pagination ordering and whether a cursor boundary is inclusive cannot be established from this single request.

### Transaction content download URL

**GET** `/vms/api/v1/sp/{sp}/units/{unit}/devices/{device}/transactions/{transaction}/contents/{content}` — **S6**

Resolves a transaction content identifier to a temporary storage download URL. No query parameters or request body are present.

Response, HTTP 200:

```json
{
  "preSignedDownloadUrl": "https://north-az1-s3.cloud.airtel.in:10446/ar-nz-hero-iot-prod-vms-event/<transaction>/<content>?<signed query>"
}
```

The exact response key is `preSignedDownloadUrl`. The endpoint returns JSON containing the URL, rather than redirecting or returning media bytes. S6's content object is not one of the supplied storage GETs, so its media type is not established by a matching download capture.

## Latest device events API

**PUT** `/control-monitor/api/v1/sp/{sp}/lastEvent` — **S11**

Retrieves the latest event for a batch of devices. Use PUT as captured, even though the observed purpose is retrieval.

The request is an array of `{deviceUUID, productType}` objects for `videoDoorbellPro`, `displayTablet`, `smartAirPurifierX4`, and `smartPlugWifi16A`.

The HTTP 200 response contains four corresponding entries. The tablet, purifier, and plug have `lastEvent: null`. The doorbell has:

```json
{
  "deviceUUID": "<device>",
  "productType": "videoDoorbellPro",
  "lastEvent": {
    "deviceUUID": "<device>",
    "unitUUID": "<unit>",
    "entityUUID": "<entity>",
    "timestamp": 1792778173015,
    "operationState": null,
    "services": {
      "recordingControl": {
        "events": {
          "stateChanged": {
            "cause": "PERSON_DETECTED",
            "coordinates": "272,274,84,175",
            "imageFileName": "/tmp/images//<device>_PRIMARY_1792778171271.jpeg",
            "record": "start",
            "stateChangeEventDefaultPriority": ""
          }
        },
        "instanceId": "0"
      }
    }
  }
}
```

The event reports person detection and recording start. Comparing `272,274,84,175` with the captured 480×640 image confirms the values behave as pixel `x,y,width,height` and enclose the detected person. `instanceId` is a string here, whereas command and shadow requests use an integer. The image basename exactly matches the object downloaded in A4; S11 does not itself return that signed storage URL.

## Storage region correction and additional captures

S9 already contains south-region snapshot URLs. Restricting storage to north was an error in the initial implementation. The application and hosted proxy now support both regional hosts and preserve the complete signed URL.

The additional September exports in Downloads include `request_response_south-az1-s3.cloud.airtel.in_muh8qissCld7005j.txt`, a successful GET from `ar-sz-hero-iot-prod-ai-event`, plus older latest-event and v2 streaming credential requests. The newly supplied `Stream Sniffed - north-az1-s3.cloud.airtel.in:10446-2.txt` is a successful signed AI image GET whose basename matches S11's `imageFileName`. Its response is binary image content, not an AI event list.

Both the September and October latest-event JSON responses contain an AI image filename but no signed download URL. These image GET captures establish the storage download step; they do not establish the request that obtains fresh signatures or an API that lists AI alerts over a time range.

## Object storage downloads

### SD-card push-pull export

**POST** `/push-pull/request` — **S23**

Accepts `filesType: "sdCardMedia"`, a list of camera-local MP4 paths, and a device target containing unit, device, entity, and `targetType: "device"`. HTTP 200 returns a `transactionId`.

**GET** `/push-pull/transaction/{transactionId}` — **S24**

Returns the transaction and one entry per requested file. Once camera upload is complete, each entry contains `uploadURL` and `downloadURL` values in the Amazon S3 `heroiot-prod-push-pull` bucket. The observed links use `X-Amz-Expires=300`. The downloaded objects advertise byte-range support and a one-day lifecycle rule. The object key is `sdCardMedia--{transactionId}--{camera local path}`.

### VMS event objects

**GET** `/ar-nz-hero-iot-prod-vms-event/{transaction}/{content}?<signed query>` — **A1, A2, A3**

Downloads event content directly from storage using the signed URL. A1 and A2 are byte-for-byte identical capture files; A3 downloads a different object. Both distinct object paths match `snapshot.downloadURL` values in S9, identifying their role as doorbell snapshots.

All three captures return HTTP 200 with `Content-Type: binary/octet-stream`, `Content-Encoding: gzip`, `Accept-Ranges: bytes`, an `ETag`, and `Last-Modified`. The exported body is `[Non-Text, Unsupported]`, so its actual image encoding cannot be inspected here. Range support is advertised; no request with a `Range` header is captured.

### AI event images

**GET** `/ar-nz-hero-iot-prod-ai-event/{unit}/{device}_PRIMARY_{timestamp}.jpeg?<signed query>` — **A4**

Downloads the event image whose basename also occurs in S11's person detection event. The object name indicates JPEG, but the response advertises `binary/octet-stream` and the export again contains `[Non-Text, Unsupported]` instead of the image bytes. HTTP status is 200, with the same general storage headers as the VMS downloads.

Both bucket patterns have `x-amz-expiration` headers describing object lifecycle expiry, which is separate from the signed URL's 24 hour authorization lifetime.

## Google Home live-view flow

**POST** `https://googlehomefoyer-pa.googleapis.com/google.internal.home.foyer.v1.HomeControlService/UpdateTraits` — **G1/G2**

This is an internal binary gRPC call made by Google Home 4.34.22.2. The decoded command targets the `hero-iot-action` integration, updates the `cameraStream` trait, requests protocol `hls`, and sets `streamToChromecast` to false. Its private request context is opaque and the request uses Google OAuth; neither can be derived from the Qubo OTP session.

The successful response maps a Google Home entity to Qubo's `partnerDeviceId`, reports the device online, supports only HLS for this flow, and reports `audioCommunicationType: NONE`. `cameraStreamAccessUrl` contains a Wowza-backed plain-HTTP master playlist with a dynamically signed `wowzatoken` plus source-device, unit, user, stream-session, and camera-session identifiers. The response's `clientContextToken` decodes to routing metadata (`hero-iot-action`, `action.devices.types.DOORBELL`, and `hls`); it is not the stream signing key.

The G5/G6 and latest G7/G8 pairs repeat the same operation on 27 October 2026 and return successful HLS sessions on the same origin with different channel suffixes, session identifiers, context tokens, and Wowza tokens. G7/G8 uses channel suffix `95`. This confirms that those values are generated per live-view request rather than stable device configuration.

The H1–H18 captures establish the complete media sequence. The master is HLS version 3 with one 250 kbps variant. Its chunklist filename embeds the Wowza token as a `tkd`-prefixed Base64 value, including `=` padding; the remaining source-device, user, unit, stream-session, and camera-session values stay in the query string. The player polls that chunklist as its media sequence grows, then downloads numbered MPEG-TS files. The observed list has a six-second target duration, begins at media sequence 1, and includes an `EXT-X-DISCONTINUITY` during startup. Segment responses use `video/MP2T` and begin with the MPEG-TS sync byte `0x47`. No separate key, init segment, audio rendition, cookie, or byte-range request occurs in this capture.

The Flutter app stores G7 server-side as a Supabase Function Secret, verifies an ID token for the configured Firebase project before replaying it or serving any HLS resource, extracts the returned master URL, and passes the media through the hosted HTTPS gateway. Qubo OTP login is not required for live view. G7 is never compiled into the public web bundle, and the repository tracks only a capture-free manifest template. Manual capture import remains available. Only the single observed live origin and exact `HLS_{device}_{channel}` session directory are allowed; playlist child paths may contain the observed Base64 padding. If Google OAuth/context expires or Qubo selects another origin, a fresh capture or allow-list update is required.

**POST** `...CameraService/GetFaceMetadata` — **G3/G4**

The request contains one entity identifier and the successful response is an empty gRPC message. It provides no face records, AI history, image filename, or signed snapshot URL.

## Relationships and practical limits

The captured API roles suggest these flows:

1. **Authentication:** the captures show phone login → returned UUID → OTP verification → returned token. The console now uses the source-backed email/password login → access and refresh tokens → proactive refresh → authenticated application requests.
2. **Doorbell history:** VMS transaction list → snapshot download URL → storage GET. To resolve another known transaction content item, use the content URL endpoint.
3. **Recording playback:** time scrubber → select camera-local MP4 paths → push-pull request → poll transaction → short-lived S3 download URL → range-capable MP4 playback.
4. **Qubo-native live streaming:** session credentials provide a UDP server destination and encryption material; RTSP related routes submit stream parameters or return availability flags. Their required call order and the native media handshake are not established.
5. **Google Home live streaming:** replay `HomeControlService/UpdateTraits` with the captured private execution context → extract `cameraStreamAccessUrl` → load `playlist.m3u8` → load its chunk playlist → continuously fetch `.ts` segments. The observed master URL is a plain-HTTP Wowza endpoint, so Firebase web playback requires an HTTPS gateway that rewrites every child URI.
6. **Detection preview:** latest event returns a person detection image filename; A4 downloads the corresponding image. The request that obtained A4's signed URL is not among the captures. The filename timestamp is the frame time and falls inside a time-scrubber recording interval in every observed October example.

All observed responses succeeded. Required versus optional fields, validation errors, other enum values, retry rules, and rate limits therefore cannot be derived. A successful device control acknowledgement does not establish that a physical action completed. Discovery and token-refresh packet captures and direct RTSP stream credentials are outside this set; the console's `/units`, `/units/{unit}/devices`, and refresh behavior are sourced from the local `qubopy` implementation instead.

## Sanitized evidence index

Raw captures are intentionally excluded because they contain account-owned
identifiers, signed URLs, and authentication material. The labels below are
retained only to connect the observations in this document; they are not links
to local files.

| Source | Original file | Observed operation or result |
| --- | --- | --- |
| S1 | Application unnumbered | Stream request with `turn` and `p2p`; `Ok` |
| S2 | Application 2 | Fan mode `qsense`; `SUCCESS_UM_006` |
| S3 | Application 3 | Fan mode `sleep`; `SUCCESS_UM_006` |
| S4 | Application 4 | Purifier shadow power `on`; `SUCCESS` |
| S5 | Application 5 | Another device shadow power `on`; `SUCCESS` |
| S6 | Application 6 | Transaction content signed download URL |
| S7 | Application 7 | RTSP related lookup; `rtspstart: false` |
| S8 | Application 8 | One day timeline; 65 recording entries |
| S9 | Application 9 | 20 missed doorbell transactions with snapshot URLs |
| S10 | Application 10 | Two day timeline; same 65 recording entries as S8 |
| S11 | Application 11 | Latest events for four devices |
| S12 | Application 12 | One UDP streaming credential record |
| S13 | Application 13 | Phone login returns UUID |
| S14 | Application 14 | OTP verification returns user and token |
| S23 | Application 23 | Requests staging of two SD-card MP4 files; returns transaction ID |
| S24 | Application 24 | Push-pull transaction returns five-minute signed upload/download URLs |
| A1 | Storage unnumbered | First VMS snapshot download |
| A2 | Storage 2 | Exact duplicate of A1 |
| A3 | Storage 3 | Second distinct VMS snapshot download |
| A4 | Storage 4 | AI detection image download |
| M1 | Push-pull media | First staged SD-card MP4 download |
| M2 | Push-pull media 2 | Second staged SD-card MP4 download from the same transaction |
| G1 | Google Home UpdateTraits request | Requests an HLS live-camera stream through `hero-iot-action` |
| G2 | Google Home UpdateTraits response | Returns online status and a signed HLS master playlist URL |
| G3 | Google Home face-metadata request | Requests face metadata for one entity |
| G4 | Google Home face-metadata response | Empty successful gRPC response |
| G5 | Fresh Google Home UpdateTraits request | Fresh authenticated HLS live-camera request used by the hosted preset |
| G6 | Fresh Google Home UpdateTraits response | Returns another signed HLS session on the same live origin |
| G7 | Latest Google Home UpdateTraits request | Latest authenticated HLS request deployed as the hosted preset; raw credentials are not tracked by Git |
| G8 | Latest Google Home UpdateTraits response | Returns live channel 95 on the supported Wowza origin |
| H1–H18 | `[105]`–`[118]` request/response captures for `13.235.191.60` | Master playlist, repeated chunklist polling, and MPEG-TS segments for one complete observed HLS startup |

Anyone reproducing this analysis should create captures only from accounts and
devices they control, sanitize them before sharing, and never commit bearer
tokens, signed query strings, raw account identifiers, or media encryption
material.
