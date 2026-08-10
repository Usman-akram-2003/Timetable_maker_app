# Responsive Desktop + Android Implementation Plan

## Strategy

### Breakpoints
- **Mobile** (`< 600px`): Single-column, BottomNavigationBar, full-width forms
- **Tablet** (`600–1024px`): Wider cards, 2-col grids, still BottomNavigationBar
- **Desktop** (`> 1024px`): NavigationRail (left sidebar), side-by-side panels, denser layouts

### Navigation change (biggest structural shift)
- Mobile/Tablet → keep current `NavigationBar` at bottom
- Desktop → switch to `NavigationRail` on the left, body takes remaining width

### Per-screen changes
| Screen | Mobile | Desktop |
|---|---|---|
| Dashboard | 2-col stat grid, single column | 4-col stat grid, wider constrained |
| Data Entry | Scrollable tabs (abbreviated), single col | Full tab labels, max-width 900 |
| Allocator | Steps stacked full-width | Steps max-width 960, wider dropdowns |
| Matrix | Horizontal scroll, compact cells | Wider cells, larger text |

### Files to create/modify
1. `lib/utils/responsive.dart` — breakpoint helpers + responsive layout widgets
2. `lib/views/screens/dashboard_screen.dart` — NavigationRail on desktop
3. `lib/views/screens/data_entry_screen.dart` — adaptive tab labels
4. `lib/views/screens/allocator_screen.dart` — adaptive padding
5. `lib/views/screens/matrix_screen.dart` — adaptive cell widths
6. `android/app/src/main/AndroidManifest.xml` — ensure portrait + landscape
