/// A failed or inconclusive query must never be confused with a running task
/// or a native confirmation that all work has stopped.
enum TaskStopStatus { stopped, running, unknown }
