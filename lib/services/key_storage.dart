import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class KeyStorage {
  static const _storage = FlutterSecureStorage();

  static const String privateKey = "private_key";
  static const String publicKey = "public_key";

  Future<void> savePrivateKey(String key) async {
    await _storage.write(
      key: privateKey,
      value: key,
    );
  }

  Future<void> savePublicKey(String key) async {
    await _storage.write(
      key: publicKey,
      value: key,
    );
  }

  Future<String?> getPrivateKey() async {
    return await _storage.read(key: privateKey);
  }

  Future<String?> getPublicKey() async {
    return await _storage.read(key: publicKey);
  }
}