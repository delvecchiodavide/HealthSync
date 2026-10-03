# HealthSync

An iOS app that reads Apple Health data on the iPhone it runs on and syncs it to Google Sheets in a Google Drive folder you choose, on a schedule you choose. It has no backend server: data goes only from your phone to your own Google account.

## What it does

- Signs in with Google (OAuth through the Google Sign-In SDK). The app never sees your password. Tokens are kept in the Keychain by the SDK.
- Creates or reuses a Drive folder made by the app, then writes **one spreadsheet per data type** (`HealthSync - Steps`, `HealthSync - Sleep`, …) plus `HealthSync - Daily Summary`.
- Syncs incrementally with `HKAnchoredObjectQuery`. Each sync uploads only new samples, and the sample UUID makes sure no row is written twice.
- When a sample is deleted in Apple Health, its row is marked `deleted = TRUE`. The row itself stays in the sheet.
- When a spreadsheet passes ~5M cells it continues in a new one: `HealthSync - Steps (2)`.
- The sync interval is set in minutes, hours or days, with a minimum of 15 minutes. Several triggers start a sync:
  - `BGAppRefreshTask`
  - `BGProcessingTask`, for large backfills
  - HealthKit background delivery
  - opening the app
  - the **Sync now** button

### Spreadsheet columns

| Type | Columns |
|---|---|
| Quantity (steps, heart rate, weight, …) | uuid, start_date, end_date, value, unit, source_name, source_bundle_id, device, timezone, synced_at, deleted |
| Sleep | … end_date, **sleep_stage**, value (min), unit, … |
| Workouts | … end_date, **activity_type, duration_min, energy_kcal, distance_km, avg_heart_rate_bpm**, … |
| Blood pressure | … end_date, **systolic_mmHg, diastolic_mmHg**, … |
| Daily Summary | date, steps, active_kcal, resting_hr_bpm, avg_hrv_ms, sleep_hours, weight_kg, workouts, updated_at |

- Dates use ISO 8601 with the UTC offset of the time zone where the sample was recorded.
- The Daily Summary covers up to 365 days of history on the first sync. After that, each sync recalculates the last 3 days in place.
- Sleep counts toward the day you woke up, and overlapping sources (for example Watch and iPhone) are counted once.

## Project layout

```
HealthSync/
├── project.yml                 XcodeGen spec (generates HealthSync.xcodeproj)
├── Config/                     Build settings; your IDs go in Secrets.xcconfig
├── HealthSync/                 iOS app target (SwiftUI)
│   ├── App/                    App entry point, AppModel (state + sync entry point)
│   ├── Services/               Google Sign-In, background tasks, notifications
│   └── Views/                  Onboarding, Home, Log, Settings, pickers
└── HealthSyncKit/              Swift package with all sync logic (Swift 6 mode)
    ├── Sources/HealthSyncKit/
    │   ├── Models/             Metric registry, settings, run log types
    │   ├── HealthKit/          HealthKitService (anchored queries, observers, daily stats)
    │   ├── Google/             GoogleAPIClient (retry/backoff), DriveService, SheetsService
    │   ├── Persistence/        SyncStore (SwiftData: anchors, uploaded-UUID index, run log)
    │   ├── Sync/               SyncEngine (single-flight, paged, checkpointed)
    │   └── Util/               Row mapping, A1 notation, helpers
    └── Tests/                  Unit + end-to-end sync tests against a fake Google API
```

To add a new data type, add one line to `HealthMetric.all` in `HealthSyncKit/Sources/HealthSyncKit/Models/HealthMetric.swift`.

## Setup

### 1. Tools

- A Mac with **Xcode 16 or later** from the App Store. After installing, run `sudo xcode-select -s /Applications/Xcode.app`.
- XcodeGen: `brew install xcodegen`.
- An iPhone running iOS 17 or later. The Simulator has almost no Health data, and background delivery doesn't behave realistically there.
- An Apple Developer account, signed in under Xcode → Settings → Accounts. A paid membership is recommended: with a free personal team, the app stops launching after 7 days and has to be reinstalled.

### 2. Google Cloud OAuth client

1. Go to <https://console.cloud.google.com> and create a project, for example "HealthSync".
2. Under **APIs & Services → Library**, enable the **Google Drive API** and the **Google Sheets API**.
3. Configure **Google Auth Platform** (the OAuth consent screen):
   - **Branding**: an app name and your email address.
   - **Audience**: User type *External*. Add your Google account under **Test users**.
   - **Data access**: add the scopes `.../auth/drive.file` and `.../auth/spreadsheets`.
4. Under **Clients** (or **Credentials**), choose **Create client → iOS**. Enter the bundle ID you'll use, for example `com.yourname.healthsync`.
5. Copy the **Client ID** and the **iOS URL scheme** (the reversed client ID).

> **Important:** while the consent screen is in *Testing* status, Google expires refresh tokens after **7 days**, so you would have to sign in again every week. For long-term personal use, set the publishing status to **In production**. Unverified apps keep working for up to 100 users; you'll see a "Google hasn't verified this app" warning once, where you choose **Advanced → Continue**.

### 3. Configure and build

```bash
cd HealthSync
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
# edit Config/Secrets.xcconfig: bundle ID, Team ID, Google client ID + reversed client ID
xcodegen generate
open HealthSync.xcodeproj
```

In Xcode, choose your iPhone as the run destination and press **Run**. Xcode downloads GoogleSignIn through Swift Package Manager on the first build. The HealthKit and Background Modes capabilities are already set up in `project.yml`, so Xcode will register them with your team automatically.

On the iPhone, make sure **Settings → General → Background App Refresh** is on, both globally and for HealthSync.

### 4. Run the tests

```bash
cd HealthSyncKit && swift test        # works without Xcode, on macOS
```

You can also press ⌘U in Xcode. The tests cover:
- row mapping for each data type
- A1 notation
- interval and due-time logic and the HealthKit frequency mapping
- backoff timing, retries on 429/5xx and the Drive 403 rate limit, and token refresh on 401
- full sync runs: first sync, deduplication, 2,500-sample paging with checkpoints, deletions, locked device, a spreadsheet deleted from Drive and re-created, Daily Summary updates in place, concurrent syncs sharing one run, and the 100-entry log limit

### 5. Testing background tasks

Run the app from Xcode, send it to the background, pause the debugger, and enter:

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.healthsync.app.refresh"]
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.healthsync.app.processing"]
```

Then resume. To test expiration while a sync is running:

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:@"com.healthsync.app.refresh"]
```

The **Log** tab shows every run with its trigger, status, row counts and errors.

## Known iOS limitations

- **Exact timing isn't possible.** iOS decides when background tasks run, based on battery, usage patterns and network. The interval you set is a target. HealthKit background delivery is limited to at most hourly for many types, steps included.
- **A locked phone blocks syncing.** Apple Health data is encrypted while the iPhone is locked. Those runs are logged as *Skipped (iPhone locked)* and don't count as failures.
- **Force-quitting stops background syncing.** If you swipe the app away in the app switcher, iOS stops background launches until you open it again. Low Power Mode also pauses background refresh.
- **Long uploads continue across runs.** A large first upload is split into pages of 1,000 samples, and progress is saved after each page. If iOS stops a run, the next run resumes from the last saved page.
- **Rare duplicates are possible.** If the app is killed between a successful upload and saving that progress locally, the same page can be uploaded again. Every row carries the sample `uuid`, so duplicates can be spotted.
- **Only app-created Drive files are visible.** The `drive.file` scope only covers folders and files the app created, so you can't pick a folder you made yourself in Drive. If you delete one of the app's spreadsheets, the app notices, creates it again and re-uploads that data type.
- **Changing folder re-uploads everything.** Choosing a different folder resets the sync state, and all data is uploaded again into the new folder.

## Privacy

- Health data leaves the phone only through HTTPS calls to Google's APIs, using your own account.
- The app has no analytics, no tracking and no server.
- Logs contain counts and identifiers only, never health values or tokens.
