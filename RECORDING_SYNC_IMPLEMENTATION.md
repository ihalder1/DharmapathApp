# Recording Sync Implementation ✅

## Overview
Implemented a complete sync mechanism between local storage and backend for voice recordings, ensuring data consistency across devices.

## Requirements Implemented

### 1. Save Recording Flow
✅ **When user saves a recording:**
- Stores recording in internal memory (local storage)
- Sends recording to backend with name and file (multipart upload)
- Uses timeout (10 seconds) to prevent hanging
- Local save succeeds even if backend fails

### 2. Sync on Screen Load
✅ **When "Record my voice" screen loads:**
- Calls API to get list of recording names from backend
- Compares names with local data store
- Downloads missing files from backend
- Uploads missing files to backend

## Implementation Details

### API Endpoints (Mock)

1. **Get Recording Names**
   - `GET /api/recordings/names`
   - Returns: `["name1", "name2", ...]` or `{"names": ["name1", "name2"]}`

2. **Download Recording**
   - `GET /api/recordings/download?name={name}`
   - Returns: Audio file (M4A format)

3. **Upload Recording**
   - `POST /api/recordings`
   - Multipart form data with:
     - `name`: Recording name
     - `uuid`: Recording UUID
     - `language`: Language
     - `user_id`: User ID
     - `created_at`: ISO timestamp
     - `file`: Audio file (M4A)

### Methods Added

#### `_getBackendRecordingNames()`
- Fetches list of recording names from backend
- Handles timeout (10 seconds)
- Returns empty list on error (graceful degradation)

#### `_downloadRecordingFromBackend(String name)`
- Downloads recording file by name
- Saves to local storage
- Adds to local recordings list
- Handles timeout (30 seconds for large files)

#### `syncRecordings()`
- Main sync orchestration method
- Compares local and backend names
- Downloads missing recordings
- Uploads missing recordings
- Reloads local recordings after sync

### Updated Methods

#### `saveRecording()`
- Now awaits backend save (with timeout)
- Uses multipart upload to send file
- Local save always succeeds
- Backend save failure is logged but doesn't block

#### `_saveToBackend()`
- Updated to use multipart file upload
- Sends actual audio file to backend
- Includes all recording metadata

## Sync Logic

```
1. Load local recordings
2. Get backend recording names
3. Compare:
   - Backend names NOT in local → Download
   - Local names NOT in backend → Upload
4. Reload local recordings
```

## Error Handling

- **Timeouts**: All API calls have timeouts to prevent hanging
- **Graceful Degradation**: Sync continues even if some operations fail
- **Logging**: All operations are logged for debugging
- **Non-blocking**: Sync runs in background, doesn't block UI

## Code Locations

### Service Layer
- `lib/services/voice_recording_service.dart`
  - `syncRecordings()` - Main sync method
  - `_getBackendRecordingNames()` - Get names from backend
  - `_downloadRecordingFromBackend()` - Download file
  - `_saveToBackend()` - Upload file (updated)
  - `saveRecording()` - Save with backend sync (updated)

### UI Layer
- `lib/screens/home_screen.dart`
  - `_syncRecordings()` - Wrapper for service sync
  - `_buildVoiceRecordingStep()` - Calls sync on load
  - `_hasSyncedRecordings` - Flag to prevent duplicate syncs

## Usage

### Automatic Sync
Sync happens automatically when:
- User navigates to "Record my voice" screen (step 1)
- Only syncs once per screen visit (prevents duplicate calls)

### Manual Sync
Can be triggered manually by calling:
```dart
await _voiceService.syncRecordings();
```

## Testing

To test the sync:
1. **Create recording locally** → Should upload to backend
2. **Delete local recording** → Should download from backend on next sync
3. **Create recording on another device** → Should appear after sync
4. **Check logs** → All sync operations are logged

## Notes

- Sync is **non-blocking** - UI remains responsive
- Sync is **idempotent** - Safe to run multiple times
- Sync handles **network failures** gracefully
- All operations have **timeouts** to prevent hanging
- Mock API endpoints are used (update URLs when real API is ready)

## Future Enhancements

- Add progress indicators for download/upload
- Add retry logic for failed operations
- Add conflict resolution (if same name exists with different content)
- Add sync status indicator in UI
- Cache sync timestamp to avoid unnecessary syncs

