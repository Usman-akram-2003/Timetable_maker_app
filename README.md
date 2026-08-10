# ??? Timetable Maker

> **Automated, clash-free university timetable generation for Pakistani colleges and universities.**

A production-grade Flutter desktop application that generates conflict-free weekly timetables for institutions running both **Intermediate** and **Bachelor** programmes simultaneously. It combines a Genetic Algorithm engine with a multi-strategy deterministic fixer to drive scheduling clashes to zero.

---

## ? Features

### Core Scheduling
- **Dual-level support** — Intermediate (F.Sc, ICS, I.Com) and Bachelor (BS) programmes in the same timetable
- **Genetic Algorithm engine** — evolves optimal schedules through crossover, mutation, and fitness scoring
- **7-strategy deterministic fixer** — "Fix Now" button resolves remaining clashes step-by-step
- **Recursive backtracking** — depth-limited chess-engine-style solver for complex deadlocks
- **N-way cyclic swap** — 3-node round-robin moves to untangle gridlock
- **Smart Day Spread** — automatically spreads Pak Studies and multi-section courses across the week without changing the locked slot
- **Phased Bachelor splitting** — last-resort splitting of 2cr ? 1+1 and 3cr ? 2+1, with automatic re-merge on the next run

### Constraint Handling
- **Morning / Evening shift rules** — Bachelor classes strictly separated into AM (slots 1–3) and PM (slots 4–6) shifts
- **Pinned (manual) allocations** — any manually assigned course is permanently locked; the engine never moves it
- **Combined class rules** — define shared sessions (e.g., multiple sections attending the same lecture)
- **Elective groups** — complex multi-subject elective pools with automatic conflict eviction
- **Friday slot blocking** — configurable blocked periods for Friday prayers
- **Credit-hour integrity** — course durations are sacred; no strategy ever reduces or "eats" credit hours
- **Pak Studies fixed to Slot 6** — enforced as a hard pin for Intermediate sections

### Data Management
- **Firebase Firestore backend** — real-time sync across devices
- **Excel import** — bulk-import courses, teachers, and classes from `.xlsx` files
- **CSV template** — downloadable course template for data entry
- **Excel export** — export the final timetable as a formatted `.xlsx` file
- **Manual pin backup** — automatic text backup of all pinned assignments

### UI / UX
- **Matrix view** — full week × period grid with colour-coded clash highlighting
- **Room matrix** — separate view showing room utilisation across the week
- **GA Report panel** — detailed generation log showing fitness score, clash count, and resolution messages
- **Fix suggestions panel** — one-click suggestions for teacher swaps and day moves
- **Selective lock dialog** — lock/unlock individual assignments before re-running the GA
- **Responsive layout** — adapts from compact to wide desktop screens

---

## ??? Architecture

```
lib/
+-- models/                  # Pure data classes
¦   +-- assignment.dart      # Core scheduling unit (teacher + course + class + slot + days)
¦   +-- course.dart          # Course with credit hours and education level
¦   +-- class_model.dart     # Class section (e.g., F.Sc Part 2-MO)
¦   +-- teacher.dart         # Teacher with department
¦   +-- time_slot.dart       # Period definition (start/end time, level)
¦   +-- elective_group.dart  # Multi-subject elective pool
¦   +-- combined_rule.dart   # Combined-class sharing rule
¦   +-- shift_rule.dart      # Morning/Evening shift constraint
¦   +-- education_level.dart # Enum: intermediate | bachelors
¦   +-- room.dart            # Physical room
¦   +-- time_slot_lock.dart  # Locked period constraint
¦
+-- services/
¦   +-- ga_engine.dart             # Genetic Algorithm (population, fitness, mutation)
¦   +-- excel_import_service.dart  # .xlsx bulk import parser
¦
+-- viewmodels/
¦   +-- data_entry_viewmodel.dart  # Main orchestrator: clash detection, Fix Now, suggestions
¦   +-- allocator_viewmodel.dart   # GA run control and parameter management
¦   +-- settings_viewmodel.dart    # App-wide settings (working days, shift config)
¦   +-- backend_viewmodel.dart     # Firestore read/write and auth
¦
+-- views/
¦   +-- screens/
¦   ¦   +-- allocator_screen.dart  # Main screen: assignment form + GA controls
¦   ¦   +-- matrix_screen.dart     # Week x period timetable grid
¦   ¦   +-- ...
¦   +-- widgets/
¦       +-- ga_report_panel.dart         # GA generation log
¦       +-- selective_lock_dialog.dart   # Lock/unlock individual assignments
¦
+-- utils/
¦   +-- responsive.dart      # Layout breakpoint helpers
¦
+-- app_theme.dart           # Design system: colours, typography, component styles
+-- main.dart                # App entry point and Firebase initialisation
```

---

## ?? Clash Resolution Pipeline

When you tap **Fix Now**, the engine runs this exact pipeline in order:

| Step | Strategy | Description |
|------|----------|-------------|
| Pass -1 | **Merge Split Courses** | Re-joins any previously split pieces back into one block |
| Pass -1b | **Bounds Repair** | Shifts any out-of-week assignments back into the valid day range |
| Pass 0 | **Elective Eviction** | Moves regular courses out of elective group slots |
| S0 | **Day Slide** | Shifts start day within the same period |
| S1 | **Period Move** | Moves to a different period, same days |
| S2 | **Full Relocation** | Moves to a completely free period + day block |
| S3 | **Pairwise Swap** | Trades periods with a compatible non-clashing assignment |
| S4 | **Cascade Chain** | Moves a blocker out first, then fills the freed spot |
| S5 | **Exhaustive Scan** | Tries every possible slot x day combination |
| S6 | **Cyclic Swap** | 3-node round-robin: A?B's spot, B?free third slot |
| BT | **Backtracking** | DFS solver for up to 8 simultaneous clashing courses |
| SD | **Smart Day Spread** | Distributes same-teacher / same-course multi-section days |
| P2 | **Split 2cr ? 1+1** | Last resort: splits Bachelor 2-credit courses (never Intermediate) |
| P3 | **Split 3cr ? 2+1** | Last resort: splits Bachelor 3-credit courses (never Intermediate) |

Every step verifies `countClashes()` **strictly decreases** before committing. Any move that does not help is fully reverted.

---

## ?? Getting Started

### Prerequisites

| Tool | Version |
|------|---------|
| Flutter | = 3.24 (Dart SDK = 3.5) |
| Firebase project | Firestore + Auth enabled |

### 1. Clone the repo

```bash
git clone https://github.com/Usman-akram-2003/Timetable_maker_app.git
cd timetable_maker_app
```

### 2. Configure Firebase

```bash
# Install FlutterFire CLI if you have not already
dart pub global activate flutterfire_cli

# Connect to your Firebase project
flutterfire configure
```

This generates `lib/firebase_options.dart` for your project.

### 3. Install dependencies

```bash
flutter pub get
```

### 4. Run (desktop — Windows recommended)

```bash
flutter run -d windows
```

---

## ?? Key Dependencies

| Package | Purpose |
|---------|---------|
| `provider` | State management (ViewModel pattern) |
| `firebase_core` + `cloud_firestore` | Real-time cloud data sync |
| `firebase_auth` | User authentication |
| `excel` | Read/write `.xlsx` files |
| `file_picker` | Native file open dialog |
| `file_saver` | Native file save dialog |
| `google_fonts` | Typography |
| `window_manager` | Desktop window control (title, size) |
| `csv` | CSV import/export |

---

## ?? Hard Constraints (Never Violated)

These rules are enforced by code guards throughout the engine — no strategy, mutation, or split can override them:

1. **Intermediate course credit hours are sacred** — never split, never reduced, never altered.
2. **Pinned (manual) assignments are immovable** — Fix Now will never touch them.
3. **Bachelor shift rules** — Morning classes stay in slots 1–3; Evening classes stay in slots 4–6.
4. **Pak Studies stays in Slot 6** — enforced via the pin mechanism.
5. **Combined class rules** — shared sessions are never flagged as clashes.
6. **Credit hour preservation on splits** — 2cr splits into exactly 1+1; 3cr into exactly 2+1.

---

## ?? Data Import Format

Use the provided `Courses_Template.csv` as a starting point. The Excel importer supports `.xlsx` files with the following columns:

| Column | Description |
|--------|-------------|
| Course Code | Unique short code (e.g., `ENG-101`) |
| Course Name | Full name |
| Credit Hours | Integer (1–6) |
| Level | `Intermediate` or `Bachelors` |
| Teacher Name | Must match an existing teacher record |
| Class | Section code (e.g., `F.Sc Part 2-MO`) |
| Room | Room name (optional) |

---

## ?? Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/your-feature`)
3. Commit your changes (`git commit -m 'Add some feature'`)
4. Push to the branch (`git push origin feature/your-feature`)
5. Open a Pull Request

---

## ?? License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

---

<p align="center">Built with Flutter + Firebase</p>
