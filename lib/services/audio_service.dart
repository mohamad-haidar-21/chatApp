import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';

class AudioService {

  final AudioRecorder recorder = AudioRecorder();


  Future<String?> startRecording() async {

    if (!await recorder.hasPermission()) {
      return null;
    }

    final dir = await getTemporaryDirectory();

    final path =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';


    await recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
      ),
      path: path,
    );

    return path;
  }


  Future<String?> stopRecording() async {

    return await recorder.stop();

  }

}