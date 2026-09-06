/// Public surface of the Tesla-style dashboard. Re-exports the
/// screen so callers import a single barrel rather than reaching
/// into the subtree.
library;

export 'application/dashboard_page_controller.dart'
    show DashboardPageController, dashboardPageControllerProvider;
export 'presentation/dashboard_screen.dart' show DashboardScreen;
