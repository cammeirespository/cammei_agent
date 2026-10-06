# Cammei — Architecture

> **Status:** Pre-code. No implementation exists yet — this document is the specification an agent builds toward, not a map of existing code. Tech-stack and naming decisions below are pinned; anything marked **TBD** is intentionally undecided and should be resolved during implementation, not guessed at.
>
> **Maintenance rule for agents:** whenever you create a real file, table, column, or endpoint that matches something proposed here, update this document in the same change — replace the proposed name/shape with the real one, and move anything newly decided out of the Open Items section. Keep this file in sync with the code as the project gets built; it should gradually convert from spec into map.

---

## 1. Overview

Cammei is a cloud-first camera and media-sharing app. Media is captured through Cammei but stored in the **user's own** connected cloud account (Google Drive, OneDrive, or Dropbox) rather than on Cammei's own servers. Cammei's backend holds metadata, references, and permissions — never the primary copy of the media itself.

**Stack:**
- Flutter — mobile frontend
- JavaScript — web frontend
- Node.js — all three backend services
- Supabase — relational database + authentication, shared across all backends

**Provider enums** (`asset_reference.provider`, `folder.provider`) are `drive` / `onedrive` / `dropbox` / `cammei`. The `cammei` option is reserved for Cammei's own storage, a later-launch feature — see §9.

---

## 2. Backend Architecture

Cammei runs **three** backend services. This split is foundational — do not merge responsibilities across them without updating this document.

### Backend 1 — Core business backend
HTTP/REST. Owns the control plane for everything except live capture and heavy byte transfer:
- User cloud-account management — connecting to providers, managing connections
- Capture- and sharing-permission handling
- Folder management
- Media records/references for files and folders stored in the cloud
- The business side of sending media (not the byte movement itself)
- Sharing/media permissions
- Notifications
- Account logic (settings, etc.)

### Backend 2 — Real-time capture backend
The only backend using WebSockets. Scoped tightly to active capture sessions:
- Capture initialization
- Capture tracking
- All WebSocket communication
- Capture completion updates

Backend 2 **never** receives the continuous media stream — the frontend writes media directly to the cloud provider while Backend 2 tracks state over the socket.

### Backend 3 — Sending / transfer backend
Kept separate because file-transfer work is CPU-intensive. This is the data-plane component Backend 1 delegates to for actual byte movement (referred to elsewhere in design discussion as the "Transfer Service" — same thing). It only streams bytes when a provider-side copy isn't possible. Backend 2 is not involved in sending at all.

### Control plane / data plane split (sending)
Backend 1 is the **sole business owner** of sending:
- Validates sender/recipient/media/provider access
- Resolves selected folders recursively
- Creates the sending-tracking and item records
- Manages/exposes transfer state
- Handles cancellation, completion, and failure

Backend 3 **only moves bytes when asked** — it owns none of the above logic. For same-provider sends, Backend 1 instructs the provider to perform a server-side copy and Backend 3 never touches the bytes; Backend 3 is only invoked for cross-provider transfers, where Cammei must act as a streaming bridge.

**Sending-progress reporting:** Backend 3 writes sending progress directly to a Supabase table from its worker thread. The frontend subscribes to that table directly when it needs to show progress, rather than polling a status endpoint. *(Table structure — TBD.)*

---

## 3. Core Conventions & Rules

These are binding rules, not suggestions — code that violates them is wrong even if it works.

1. **Cloud-first storage.** Media bytes live in the user's own cloud provider, never permanently on Cammei's backend.
2. **Clean backend separation.** Backend 1 (control plane) / Backend 2 (real-time capture) / Backend 3 (transfer data-plane). Don't cross these lines.
3. **Avoid unnecessary media movement.** Use provider-side copy for same-provider operations. Cammei only streams bytes through itself when bridging across different providers.
4. **Frontend sends selections, not full contents.** The frontend sends selected folder/media IDs only; the backend resolves and reconstructs the full hierarchy server-side.
5. **Queues hold work, not requests.** A worker processes queued jobs; long-running operations are acknowledged asynchronously rather than held open.
6. **Per-item status.** Sending/sharing items each carry their own status so work can retry/resume without repeating completed items.
7. **Unique string IDs everywhere.** Every table's ID, in every table (Supabase and on-device), is a generated unique string — never a sequential integer or a short code.
8. **Retry policy.** Keep retrying transient failures (e.g. network blips). Stop and surface an error on non-retryable failures: revoked auth, an invalid name, a storage-quota issue.
9. **Nullable request fields get sensible defaults, not errors.** E.g. an omitted `limit` defaults to infinity (return all media).
10. **Shared "named-after-source" subfolder convention.** Incoming/permitted content is filed into a subfolder named after its source — the capturer's device name for capture permission, the sender's username for received sends. This is one deliberate shared pattern, not two separate designs; apply it consistently to any future "incoming content" feature too.
11. **Multi-account support.** A user may connect more than one account on the same provider. Which account to use for a given action is a choice made by the user on the frontend — never auto-resolved by the backend.
12. **Trusted-device auth.** Device identity persists via `user_devices` (`deviceId` generated and stored on-device at install). Reinstalling the app must not by itself deauthorize a device — only an explicit logout or revoke should.

---

## 4. Cloud Storage Structure & Naming

Once a user grants access to a provider, Cammei creates/reuses a **"Cammei"** folder on that provider containing three subfolders — **Photo's**, **Video**, **audio** — together referred to in this document as the **"main folders."**

Under each main folder, **monthly folders** are created, e.g. `Cammei → Photo's → January`. A year-level folder is **never created on the provider** — year grouping is UI-only, derived from each monthly folder's `dateCreated`. The currently-active monthly folder is referred to here as **"the Root folder"** — its `folder` row carries `folderType = "parent"`.

> "Main folders" and "the Root folder" are **documentation terms only**, not literal folder names shown to users. Real folder names on the provider follow whatever naming the system/user actually applies.

Incoming sent media is filed under a **"Received"** folder inside the current Root folder (created if it doesn't exist), with a subfolder per sender's username inside that (see Convention #10, §7.5).

---

## 5. Database Schema

All tables live in Supabase unless marked **(on-device / SQLite)**. Every ID, in every table, is a generated unique string (Convention #7).

### 5.1 `users`
| Field | Notes |
|---|---|
| userId | |
| name | |
| username | unique |
| type | enum: business / creator / private — **use TBD, deferred to production** |
| role | enum: user / admin |
| isSpecial | bool — **use TBD, deferred to production** |
| assetId | |
| email | |
| password | nullable |
| createdWithOAuth | bool |

### 5.2 `user_devices`
| Field | Notes |
|---|---|
| ownerId | |
| deviceName | |
| OS / platform | |
| deviceId | generated and stored on-device at install |
| isLoggedIn | bool |
| lastLogin | |
| revokeAccess | bool — `true` denies auth on that device |
| distrusted | bool |
| enabled_notification | bool |
| push_token | |

### 5.3 `user_cloud` (one row per connected provider account)
| Field | Notes |
|---|---|
| ownerId | |
| provider | drive / onedrive / dropbox |
| providerAccountId | |
| email | |
| providerAccessTokenId | **must be encrypted** |
| providerRefreshToken | **must be encrypted** |
| expiresAt | |
| scopes / permissions | |
| status | |
| lastUsed | |

### 5.4 `capturing` (active capture session)
| Field | Notes |
|---|---|
| id | |
| ownerId | |
| deviceId | |
| captureType | video / audio |
| status | preparing/capturing/paused/completed/offline/failed — reflects **live connection state only**, see rule below |
| fileName | |
| folderName | the chosen folder, or default |
| folderId | must be sent by the client |
| provider | |
| providerFileId | |
| startedAt / endedAt | |
| capturerId | user id of the person capturing |
| duration | |
| lastActivityAt | |
| cloudUploadStatus | preparing/uploading/complete/offline/failed |
| localCopyExist | bool |
| offlineCreated | bool |
| retryCount | |
| errorCode / errorMessage | arrays, indexed to retry attempts |

**Rule:** `status` only reflects the live connection state with the frontend — it has **no link to row deletion**. The row is deleted **only** when the user explicitly clicks stop recording, closing the connection.

### 5.5 `photo_tracking`
| Field | Notes |
|---|---|
| id | |
| ownerId | |
| deviceId | |
| cloudConnectionId | |
| folderId | |
| folderName | |
| provider | |
| filename | |
| status | |
| capturerId | |

**Rule:** a row is **not** created for every photo. Create one only (a) while a newly-requested folder is still being created, to track photos taken during that wait, or (b) for photos captured offline, so reconnecting can track the bulk upload. Once a folder exists, later photos into it need no tracking row.

### 5.6 `asset_reference`
| Field | Notes |
|---|---|
| id | |
| userId | owner |
| assetType | enum: photo / video / audio |
| storageType | enum: external / local |
| provider | drive / onedrive / dropbox / cammei |
| accessState | enum: active / inactive |
| revokedAt | |

A new set of rows (photo/video/audio) is created the first time a user connects a given provider. **This table is not itself a folder** and has no `providerFolderId` — it's a logical reference grouping all of a user's `folder` rows for that media-type + provider. Requests default to the `Cammei → Photo's/Video/Audio → month` path, so the monthly (parent-type) `folder` rows are what carry the real `providerFolderId`, reached via `assetReferenceId`.

### 5.7 `folder`
| Field | Notes |
|---|---|
| id | |
| assetReferenceId | points to the `asset_reference` row for this provider/media-type |
| folderType | enum: parent / child |
| parentFolderId | null if this folder is itself a parent |
| name | |
| storageType | external / local |
| provider | |
| providerFolderId | the provider's stable folder ID — the reference of record, **not** the name |
| state | active / zipped / missing / creating |
| dateCreated | |
| local_folder_id | nullable — identifies a folder being tracked locally on a device (Track Folder, §8) |

Parent-type folders are created on a monthly basis — these are "the Root folder" (§4).

### 5.8 `capture_sharing_requester`
| Field | Notes |
|---|---|
| id | |
| senderId | |
| receiverId | starts null; filled once accepted, or once a username is entered directly |
| providerToUse | drive / onedrive / dropbox |
| status | |
| providerTableId | references the sender's row in `user_cloud` for that provider |

Sends the notification for a receiver to accept granting capture permission into their own cloud storage.

### 5.9 `capture_permission`
| Field | Notes |
|---|---|
| id | |
| ownersId | |
| capturerId | |
| provider | |
| providerAccountId | |
| cloudPermissionTableId | references `user_cloud` — no raw tokens stored here |
| status | |
| deviceId / deviceName | the capturer's device |

Once accepted, the owner's storage appears as another provider option on the capturer's device, and a folder named after the capturer's device is created under the owner's current Root folder (Convention #10).

### 5.10 `media_sending_reference`
| Field | Notes |
|---|---|
| id | |
| senderId / receiverId | |
| providerAccountId | sender's account |
| receiverProvider / receiverProviderId | destination account, tracked separately from the sender's |
| state | enum: awaiting / accepted |
| status | enum: pending / processing / completed / failed / cancelled |
| error | |
| provider | |
| mediaType | |

Tracking record for a send request; referenced by rows in `individual_sending_item`.

### 5.11 `individual_sending_item`
| Field | Notes |
|---|---|
| id | |
| transferReferenceId | |
| itemType | enum: file / folder / photo / video / … |
| itemId | the actual file/folder id |
| name | |
| status / error | |
| retries | max 3 |
| parentId | items sharing a parentId land in the same destination folder |
| createdParentFolderId | nullable — destination folder created for this item during the transfer |

One row per file or folder in a send, including folders themselves.

### 5.12 `media_sharing_receiver`
| Field | Notes |
|---|---|
| id | |
| shareId | references `media_share` |
| receiverId | |
| status | enum: pending / accepted / rejected |
| accessExpiresAt | nullable |

New table — sending has no equivalent. Lets one share support multiple recipients: if a row already exists for a share and another person joins the same link, a new row is created for them too.

### 5.13 `media_share`
| Field | Notes |
|---|---|
| id | |
| ownersId / receiverId | |
| provider / providerAccountId | |
| status | enum: pending / active / inactive |
| expiresAt | nullable |
| access | enum: view (view-only for now) |
| type | enum: folder / video / audio / image |

Functionally plays the same role as `media_sending_reference`, for the sharing flow.

### 5.14 `media_share_item`
| Field | Notes |
|---|---|
| id | |
| shareId | |
| itemType | file / folder |
| itemId | folder or media id |
| parentId | references the nesting folder within this same table |
| originalName | |

Functionally plays the same role as `individual_sending_item`, for the sharing flow.

### 5.15 `notification`
| Field | Notes |
|---|---|
| id | |
| ownerId | |
| title | |
| type | enum — only "added" confirmed so far; **remaining values TBD, decide during development** |
| body | |
| data | JSON, shape determined by `type` |
| readAt | |

---

### 5.16 On-device (SQLite) tables

Built specifically for capture operations and local-folder tracking; let uploads resume mid-chunk after a device reconnects.

**Active-Capture**
| Field | Notes |
|---|---|
| online_id | the real backend `capturing` row id — set immediately if online at capture start, else null until reconnect |
| offline_id | never null — locally-generated unique id, also used as `offline_chunk_id` on Chunk-table |
| mediatype | |
| filename | |
| status | recording / offline / uploading / completed / awaiting |
| wasActive | bool |
| local_uri | |
| providerT | |
| providerId | |
| cloud_folder_id | |
| cloud_file_id | nullable |

Created when recording starts; references the Chunk-table.

**Chunk-table**
| Field | Notes |
|---|---|
| offline_chunk_id | |
| unique_chunk_id | |
| chunk_index | |
| local_uri | |
| size_bytes | |
| uploaded_bytes | |
| status | pending / uploading / uploaded / failed |
| retry_count | |

Holds each chunk's location on the device for offline-captured media.

**local_folder_tracking** (Track Folder, §8)
| Field | Notes |
|---|---|
| storage_id | TEXT NOT NULL |
| local_folder_id | TEXT NOT NULL |

Works alongside `folder.local_folder_id` to identify folders being tracked locally on a device; lets a tracked external drive be re-detected automatically after disconnect/reconnect.

---

## 6. API Reference

### 6.1 Backend 1 — REST

**Device Auth**
- `POST /devices/check` — body: `uniqueDeviceId, deviceName, OS` → returns `isTrusted, isLoggedIn, ownerId, isAccessRevoked`
- `POST /devices/register` — body: `ownerId, uniqueDeviceId, deviceName, OS, isTrusted` → returns `success`
- `GET /devices` — header: `ownerId` → returns array of `{deviceName, OS, isLoggedIn, id}`
- `GET /devices/{deviceId}` → returns `deviceName, OS, isLoggedIn, id, isTrusted, isAccessRevoked`
- `POST /devices/update` — body: `shouldLogout` (nullable), `revokeAccess` (nullable), `isTrusted` (nullable), `uniqueDeviceId` → returns `success`
- `POST /devices/trust` — body: `uniqueDeviceId, ownerId` → returns `success`
- `DELETE /device/delete/{deviceId}` — header: `currentDeviceId` → returns `success`

> **Device-auth flow:** authentication itself runs through Supabase; Backend 1 handles verification. If the app is logged out/not fully authenticated, it checks the unique device id in local storage and calls `/devices/check`. If trusted, the user still needs an OTP or password step (never fully silent); otherwise a full credential + OTP flow runs via Supabase.

**User & Account**
- `POST /user/changeUserName` — body: `userId, new-name, old-name, unique-device-id`
- `POST /user/changeEmail` — **not in use for now** (confirmed out of scope)
- `POST /user/changeType` — body: `currentType` (enum per `users.type`), `ownerId, newType`
- `GET /user/currentType` — header: `userId` → returns `role, currentType`
- `GET /user/getUsername` — header: `ownerId` → returns `username`
- `POST /user/changeRole` *(admins only)* — body: `editorId, ownerId, newRole` (enum) → returns `success`
- `POST /user/makeSpecial` *(admins only)* — body: `editorId, ownerId, makeSpecial` (bool) → returns `success`
- `POST /user/deleteAccount` — body: `accountId, reason, password` (nullable)
- `GET /user/getAccountInfo` — header: `ownerId` → returns public displayable info + needed variables

> Admin-only endpoints are never exposed in the user-facing app.

**Cloud Account**
- `GET /cloud/accounts` — header: `ownerId, requesterId` → returns list of `{provider, providerId, status, id, expiresAt}` (includes capture permissions)
- `GET /cloud/account/{id}` → returns `provider, providerId, isPermissionGranted, status, id` — **do not return the raw access token here**
- `POST /cloud/update` — body: `lastUsed, status, id, ownerId, providerAccessToken, providerRefreshToken, permissions, email` → returns `success`
- `DELETE /cloud/delete/{id}` → returns `success`
- `POST /cloud/add` — body: `ownerId, provider, providerAccountEmail, accessToken, refreshToken, tokenExpiry, permission, status` → returns `success, id`
- `POST /cloud/createRootFolders` — body: `ownerId, cloudTableId`
- `POST /cloud/storage` — body: `providerTableId, ownerId` → returns `storage (kb), used, left`

**Folder**
- `POST /cloud/folders` — body: `ownerId, providerTableId, folderId` (nullable), `mediaType` → returns a list structured via `parentId` references *(shape TBD)*. When `folderId` is null, returns the root/main folder (Photo's/Video/audio) selected via `mediaType`, not a specific subfolder
- `GET /cloud/folders/{folderId}/{ownerId}` → returns full folder info from cloud + database
- `POST /cloud/folders/createFolder` — body: `parentId, providerId, provider, name, forType` (ignorable) → returns `success`
- `POST /cloud/folder/Rename` — body: `folderTableId, newname` → returns `success`
- `DELETE /cloud/folder/delete/{id}/{ownerId}` → returns `success`

**Media**
- `POST /cloud/media/photos`, `/cloud/media/videos`, `/cloud/media/audios` — each body: `limit` (nullable), `parentFolderId` (nullable), `providerTableId, ownerId` → returns a list *(shape TBD)*
- `GET /cloud/media/folderItems` — header: `folderTableId, providerTableId, ownerId` → *(shape TBD)*
- `POST /cloud/media/delete` — body: `type` (enum photo/video/audio), `providerTableId, mediaCloudId, ownerId` → returns `success`
- `POST /cloud/media/rename` — body: `mediaId, newname, ownerId, providerTableId` → returns `success`
- `POST /cloud/media/getItem` — body: `mediaType, mediaId, providerTableId, ownerId` → returns `uri`, etc.
- `POST /cloud/media/moveMedia` — body: `type, providerTableId, mediaId, shouldDeleteOriginal, newDirectoryFolderTableId` → returns `success`
- `GET /cloud/media/getmetadata/{mediaId}` → returns full filtered metadata
- `POST /cloud/media/search` — body: `text, ownerId, type` (enum photo/videos/audio/all), `providerTableId` (nullable), `folderTableId` (nullable)

**Sharing**
- `POST /share/create` — body: `[selected items], cloudProviderTableId, ownerId, mediaType` → returns `acceptanceUrl, referenceTableId, state`
- `POST /shared/shareWithUsername` — body: `username, shareMediaTableId, expiresAt` (nullable) → returns `success`
- `GET /share/shareConnectionChecker` — header: `ownersId` → returns list of sharing connections with their urls
- `GET /share/checkIfShared/{ownersId}/{mediaId}` — confirms whether the folder/media item the user is viewing is publicly shared → returns `isShared, itemId` (row id on `media_share_item`), `type, mediaShareTableId`
- `POST /share/makePrivate` — body: `itemId, ownerId, mediaShareTableId` → returns `success`. Removes a media item or folder from a public shared channel by deleting it from `media_share_item`; if it's a folder, nested subfolders/media are deleted too
- `POST /share/listShareData` — body: `shareTableId, viewerId` → returns list of root items plus all subitems

**Sending**
- `POST /send/create` — body: `[selected items], cloudProviderTableId, ownerId, mediaType` → returns `acceptanceUrl, id`
- `POST /send/sendWithUsername` — body: `username, mediaSendingReferenceTableId, ownerId` → returns `state`
- `GET /send/Accept/{tableId}` — header: `didAccept` (bool) → returns `sendingStarted` (bool). On reject (`didAccept=false`), `media_sending_reference`'s `state` and `status` both become `cancelled`, and the `individual_sending_item` rows are deleted one by one
- `GET /send/ActiveSendingOperations` — header: `ownerId` → returns list of active sending operations (including ones this user is receiving), each with `state + percentageLeft`

**Capture Permission**
- `POST /capture/makePermission` — body: `ownerId, receiverUsername` (nullable), `provider, providerTableId` → returns `uniqueAcceptanceUrl, id`
- `GET /capture/AcceptPermission/{permissionId}` → returns `accepted` (bool), `providerId, ownerId, provider, permissionTableId, providerTableId`
- `GET /capture/permissionList` — header: `userId` → returns list of permissions given/accepted/awaiting
- `DELETE /capture/removePermission` — header: `permissionTableId, acceptorId` → returns `success`

**Notification**
- `POST /notifications/confirm` — body: `notificationTableId, notificationDeviceTableId` → returns `isActive, title, description, notifyType` (enum, more values TBD)
- `POST /notifications/addDevice` — body: `pushToken, platform, enabled, uniqueDeviceId, ownerId` → returns `success`
- `POST /notification/shouldEnable` — body: `uniqueDeviceId, ownerId` → returns `success` — toggles notifications on/off for a device

### 6.2 Backend 2 — WebSocket

Not REST — capture operates over persistent WebSocket connections. All three connections must include `capturerId`/`ownerId`.

- **`/capture`** — message: `captureType, folderId, deviceTableId, capturerId, filename, providerT, providerId, folderName` → connection emits: ongoing progress events, confirmation the capture row + cloud file were created, chunk-upload-retry events; can also carry a reconnect request. One continuous session per device — no item list.
- **`/phototracker`** — message: `delayReason` (enum `createFolder`/`wasOffline`), `availablePhotos, folderId` (nullable), `filename, providerT, providerId, folderName` (nullable), `ownerId`. Can cover multiple queued items at once.
- **`/offlineupload`** — message: `mediaType` (video/audio), `folderId, deviceTableId, providerT, providerId, filename, folderId` (nullable), `folderName` (nullable), `itemLength` + a list of each queued item's individual info.

> **`providerT`** is an enum of `drive`/`onedrive`/`dropbox`/`"Sharing"`. `"Sharing"` means the capturer is capturing for someone else via a granted capture permission — `providerId` is then the `capture_permission` table's id, and Backend 2 must call a Backend 1 API to resolve the real provider + providerId (guard with an if-condition). Same resolution applies on `/phototracker`.

### 6.3 Backend 3 — REST (transfer)

- `POST /sameprovider` — body: `providers, media_sending_reference_table_id` → returns `started (bool), tracking_id`
- `POST /google-drive-transfer` — body: `receiving_provider, media_sending_reference_table_id` → returns `started (bool), tracking_id`
- `POST /onedrive-transfer` — same shape
- `POST /dropbox-transfer` — same shape

---

## 7. Application Flows

### 7.1 On app launch
1. Check authentication
2. Check the upload queue and resume uploads if online
3. Check which folders are allowed to track/upload local changes
4. Check the notification table
5. Check the capture- and sharing-permission tables for anything needing a popup prompt
6. Ensure the app has all required device permissions
7. Check cloud authentication state

### 7.2 Opening the camera
1. Check whether the user has an active cloud provider connected
2. If not: block capture, show the auth/permission page instead
3. If yes: open the camera UI

### 7.3 Photo capture flow
1. If a new folder is needed, frontend requests folder creation from **Backend 1**
2. While that folder creation is in progress, frontend also asks **Backend 2** to create a `photo_tracking` row, to track photos taken during the wait (Backend 1 owns the folder row, Backend 2 owns the tracking row — the frontend coordinates both)
3. Backend 1 creates the folder on the provider, retrying automatically unless there's a non-retryable reason (revoked auth, invalid name, storage quota — see Convention #8)
4. Success returned to frontend
5. Frontend uploads the image into the new folder using the returned folder id
6. Frontend sends a "done" request afterward

**Root-directory API:** one endpoint returns the root directory id of the selected provider by default and lets the user change directory; a second returns the full folder structure as JSON for a picker.

### 7.4 Video / audio capture flow
1. User taps record
2. App gets/creates the folder (root-folder) id
3. Capture starts at the selected fps
4. Footage is broken into chunks, encoded every 2 seconds
5. A capture-initialization request is sent if online; if offline, chunks buffer locally until connectivity returns, then the request proceeds
6. The request opens a WebSocket to **Backend 2** (`/capture`)
7. Before creating the `capturing` row, Backend 2 first creates an empty placeholder file (`.mp4` or `.mp3` for now) in the target folder and returns its location as the write target
8. Backend 2 creates the `capturing` row and returns success over the socket
9. Frontend streams chunks to cloud storage over the socket connection, updating capture state as it goes
10. On finish, frontend sends a "done" signal
11. Backend makes final DB updates, the socket closes, and the `capturing` row is deleted (see rule in §5.4)

### 7.5 Offline capture & reconnect
Local SQLite (`Active-Capture` + `Chunk-table`, §5.16) tracks captures independent of connectivity.
1. If a capture starts with internet, `online_id` is set immediately; `offline_id` is always generated too
2. If captured fully offline, `online_id` stays null on `Active-Capture` until the device reconnects
3. On reconnect, the local queue is scanned
4. Items with `wasActive=true` (live/in-progress when connectivity dropped) resume via the normal `/capture` WebSocket from where upload stopped
5. Fully offline-created items, and items that had started uploading but went offline, go through `/offlineupload` instead — which checks each item's `Active-Capture` status, and if "awaiting," continues the upload
6. `/offlineupload` returns the backend capture-table id for every `Active-Capture` item it processes

### 7.6 Capture-permission-sharing flow
1. User taps "share capturing permission"
2. Backend 1 creates a `capture_sharing_requester` row with `receiverId` null, returns a shareable URL
3. Whoever opens the URL and accepts becomes the receiver — `receiverId` fills in, a `capture_permission` row is created
4. User is redirected into the capture UI, behaving like a normal capture from there
5. The granted permission appears as a selectable option alongside real cloud providers on the capturer's device, and a folder named after the capturer's device is created under the owner's current Root folder

*Alternative path:* entering the receiver's unique username directly fills in `receiverId` and notifies that specific user, instead of the open URL.

### 7.7 Media sending flow
1. User selects media/folders to send
2. Frontend collects the relevant folder/file ids
3. Backend 1 resolves the selected folders (and subfolders, with parent ids) from the `folder` table
4. Backend 1 looks up the sender's cloud-connection info
5. Backend 1 creates a `media_sending_reference` row, plus one `individual_sending_item` row per file/folder found
6. Response includes a shareable acceptance link
7. Once the receiver clicks and accepts, sending begins (→ Backend 3, §7.8)

Sending branches on a provider-pair check: (1) same-to-same provider, (2) Drive → one of the other three, (3) OneDrive → the other three, (4) Dropbox → the other three.

### 7.8 File-transfer flow (run by Backend 3)
1. Receiver accepts the sent files
2. Backend creates a "Received" folder inside the receiver's current monthly Root folder if it doesn't exist, then a subfolder named after the sender's username inside that (Convention #10)
3. A conditional check determines which provider-pair case applies
4. **Same-provider:** loop through folders/subfolders in `individual_sending_item`, recreate them via provider-side operations, write each new folder's id onto `createdParentFolderId`
5. A second loop requests the actual file transfers, placing each file using its item's `createdParentFolderId`
6. **Cross-provider:** same two-loop structure, but the file-chunk transfer streams through Cammei's own transfer backend (a channel on a child-process thread), not directly through the provider
7. Once every loop finishes, the child process is killed and the sending-reference/item rows are deleted
8. A notification is sent to the user

Before any sending starts, an in-memory map of all active sending processes (keyed by id) is kept so progress can be queried while running.

### 7.9 Sharing flow
Mirrors sending's mechanics but stops after updating `media_share_item` — no byte transfer, since sharing grants view access rather than moving files. Once the recipient accepts via the sharing URL, a `media_sharing_receiver` row is created referencing `media_share`'s id; multiple receivers can join one share this way.

Functional correspondence: `media_share` ↔ `media_sending_reference`; `media_share_item` ↔ `individual_sending_item`; `media_sharing_receiver` is new (sending has no equivalent).

---

## 8. Frontend Structure (Flutter mobile)

> Layout, visual structure, and color scheme are the designer's call to change freely — this section is the **logical screen/flow structure only**, not a fixed visual spec. Treat it the way you'd treat a UX brief: build toward the described behavior, not pixel-for-pixel toward this wording.

Three main areas reachable from the bottom nav: **Launch/Camera page** (center, default), **Hub page** (left), **Profile page** (right).

### 8.1 Launch / Camera page
Opens by default on app launch with the bottom nav visible. Shows a cloud-provider dropdown, a "share capture permission" button, and header capture settings (fps, resolution, add folder, more "⋮"). Tapping "open camera" opens the full capture UI — bottom nav hides, full capture controls appear. Default mode: Photo.

**Capture UI:** three nav tabs (Video / Photo / Audio) switch capture mode and the header's capture settings. Controls: begin-capture/take-photo, switch-camera-facing, and (video) a take-photo-while-recording button. Audio mode looks like a normal audio recorder but keeps the same controls. "More (⋮)," top-right, opens a settings menu with "change cloud provider" pinned at the top (rest of the content TBD). The camera's first screen also has a button to grant capture-sharing permission.

> The header's "add folder" and the sidebar's "Track Folder" (§8.4) are **different features** — do not conflate them. The camera header's add-folder creates a new folder on the cloud provider under Cammei and redirects future captures of that media type into it. Track Folder connects an existing local device folder instead.

### 8.2 Hub page (gallery/library)
Top: app name (bold) + a "providers" nav linking to a list of connected-cloud-provider widgets (provider name bold, signed-in email below each) — tapping one opens that provider's main-folders activity. A "Shared" nav below opens an activity listing the usernames of people the user is sharing media with.

**Folder drill-down:** tapping a main folder (e.g. Video) shows a loading state, then the monthly folders with a few recent media items for preview. Inside a monthly folder: the user's own captured media/folders display normally, alongside a "Received" folder (subfolders named per sender's username, containing that sender's shared media) — kept minimized behind a "View All" button that expands to show all received media. Folders/media have a "more" button for options; opening a media file shows an info icon near the filename and share/send/delete icons at the bottom. A tappable breadcrumb-style path at the top (with a dropdown) lets users jump between folder levels quickly.

**Shared activity** (items others granted access to) is organized by owner's username; tapping one opens a folder/media view similar to the main gallery.

### 8.3 Hub page sidebar
Add Cloud, Provider Info, Track Folder, Offline Queues, Feedback, MVP version + build number.

- **Add Cloud** — opens the same provider-picker activity as the camera page's "+" (Google Drive / OneDrive / Dropbox); picking one hands off to that provider's auth flow, which returns the granted permission.
- **Provider Info** — shows, per connected account: email, total storage, storage used, storage left, and permission-session info (granted/expires) in a repeatable list.
- **Offline Queues** — shows a list of pending upload processes (backed by an existing API; not yet matched to a specific endpoint name in these notes).
- **Feedback** — a rating/experience page with a text field for feedback.

### 8.4 Track Folder
Lets a user pick a **local device folder** (external or internal drive) for Cammei to sync — distinct from the cloud "main folders."
- Uses a **background service**, since it needs to track all changes on the folder. **MVP scope: create-operations only** (new folder created, new media item created) — not edits/deletes yet.
- Storage: `local_folder_id` on the `folder` row; the backend folder-table id is also stored in the on-device `local_folder_tracking` SQLite table (§5.16). A tracked external drive stays tracked across disconnect/reconnect, re-detected automatically via the stored `storage_id` + `local_folder_id`.
- **Upload flow:** based on the offline-upload sequence. Three individual checks run — one each for photos, videos, audio found in the tracked folder — each returning that media type's location and folder structure; results are queued, used to create the respective tracking tables, then uploaded, mirroring offline-captured media.
- **Connecting behavior:** if Cammei finds audio in the tracked folder, it uses/creates the audio main folder as the destination; if it finds photos, it tries to recreate the local folder's structure on the cloud, starting from the tracked media type's root folder.

### 8.5 Profile page
Shows the user's name + username, navs: Devices / About / Notifications / Feedback, a row of social-media handles, app version + build number, and a logout button.

- **Devices** — lists all authenticated devices; tapping one shows trusted/revoked status, OS, logged-in state, last login, device name, plus toggles (only if trusted): make trusted/untrusted, log out of that device, permanently revoke access.
- **Notifications** — a simple prompt asking whether the user wants notifications on this device.
- **About** — general Cammei info plus a contact email.

---

## 9. Monetization (MVP scope note)

The **MVP includes neither a subscription nor the "Cammei Cloud" storage upgrade** — both are deferred to a later launch.

- **Premium subscription:** price not yet decided (an earlier ~$2/month figure is no longer settled). Planned perks, timing TBD: removes ads, adds AI recording optimization and background-sound removal.
- **"Cammei Cloud" storage:** a separate, later-launch upgrade — a one-time payment for **lifetime** storage (amount still being decided), with per-1GB pricing at launch also not yet decided.
- **AI media search/identification:** planned to be free for all users, regardless of tier.

This note exists so pricing/entitlement logic is not accidentally built into the MVP; revisit when the later launch is scoped.

---

## 10. Open Items

Resolve these during development — they are not blocking the architecture, but they are gaps an implementing agent should not silently fill in:

- Response/query shapes still TBD: `/cloud/folders`, `/cloud/media/photos|videos|audios`, `/cloud/media/folderItems`
- `notification.type` enum values beyond `"added"`
- `isSpecial` and `users.type` — fields exist, functional use deferred to production
- `/user/changeEmail` — endpoint listed but inactive for now
- Offline Queues screen's backing endpoint — not yet named in design notes
- Sending-progress Supabase table structure (written by Backend 3, read by the frontend)

---

## 11. Maintenance Instructions for Agents

- When you create a real table matching one in §5, update that table's row to reflect the actual column names/types if they end up differing from this draft.
- When you implement an endpoint from §6, replace its entry with the real route, and move its response shape out of "TBD" once decided.
- When an Open Item (§10) gets resolved, delete it from §10 and fold the decision into the relevant section above.
- Do not restructure §8 (frontend) based on this doc alone — it is intentionally loose; defer to the designer's actual screens once those exist, and update this section to match them.
- Keep §3 (Core Conventions) authoritative: if an implementation detail conflicts with a rule there, the rule wins unless the person building Cammei explicitly changes the rule here first.
