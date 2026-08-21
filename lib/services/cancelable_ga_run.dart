import 'dart:async';
import 'dart:isolate';
import 'ga_engine.dart' show GaInput, GaOutput;

/// Thrown into the awaiting Future when [CancelableGaRun.cancel] is called
/// before the isolate produces a result.
class GaCancelled implements Exception {
  const GaCancelled();
  @override
  String toString() => 'GA run cancelled';
}

class _Job {
  final FutureOr<GaOutput> Function(GaInput) callback;
  final GaInput input;
  final SendPort replyTo;
  const _Job(this.callback, this.input, this.replyTo);
}

Future<void> _entry(_Job job) async {
  final result = await job.callback(job.input);
  job.replyTo.send(result);
}

/// Like [compute], but keeps a handle so [cancel] can kill the worker
/// isolate outright. A busy GA generation loop has no way to notice a
/// cooperative "please stop" flag set from the calling isolate — killing
/// the isolate is the only real way to stop it mid-run.
class CancelableGaRun {
  Isolate? _isolate;
  bool _cancelled = false;
  final _completer = Completer<GaOutput>();

  Future<GaOutput> run(FutureOr<GaOutput> Function(GaInput) callback, GaInput input) async {
    final port = ReceivePort();
    _isolate = await Isolate.spawn(
      _entry, _Job(callback, input, port.sendPort),
      onError: port.sendPort, errorsAreFatal: true,
    );
    port.listen((data) {
      if (_completer.isCompleted) { port.close(); return; }
      if (data is List) {
        // onError payload shape: [errorString, stackTraceString?]
        _completer.completeError(Exception(data.isNotEmpty ? data.first : 'isolate error'));
      } else {
        _completer.complete(data as GaOutput);
      }
      port.close();
      _isolate?.kill();
    });
    return _completer.future;
  }

  void cancel() {
    if (_cancelled || _completer.isCompleted) return;
    _cancelled = true;
    _isolate?.kill(priority: Isolate.immediate);
    _completer.completeError(const GaCancelled());
  }
}
