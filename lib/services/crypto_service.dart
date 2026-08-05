import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart';
import '../models/encrypted_message.dart';
class CryptoService {
  final X25519 algorithm = X25519();

  Future<SimpleKeyPair> generateKeyPair() async {
    return await algorithm.newKeyPair();
  }

  Future<String> getPublicKey(SimpleKeyPair keyPair) async {
    final publicKey = await keyPair.extractPublicKey();

    return hex.encode(publicKey.bytes);
  }

  Future<String> getPrivateKey(SimpleKeyPair keyPair) async {
    final privateKey = await keyPair.extractPrivateKeyBytes();

    return hex.encode(privateKey);
  }
  Future<SecretKey> deriveSharedKey({
    required String myPrivateKeyHex,
    required String myPublicKeyHex,
    required String otherPublicKeyHex,
  }) async {
    final privateKey = SimpleKeyPairData(
      hex.decode(myPrivateKeyHex),
      publicKey: SimplePublicKey(
        hex.decode(myPublicKeyHex),
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    );

    final otherPublicKey = SimplePublicKey(
      hex.decode(otherPublicKeyHex),
      type: KeyPairType.x25519,
    );

    return await algorithm.sharedSecretKey(
      keyPair: privateKey,
      remotePublicKey: otherPublicKey,
    );
  }
  final AesGcm cipher = AesGcm.with256bits();

  Future<EncryptedMessage> encryptMessage({
    required SecretKey sharedKey,
    required String message,
  }) async {
    final nonce = cipher.newNonce();

    final secretBox = await cipher.encrypt(
      message.codeUnits,
      secretKey: sharedKey,
      nonce: nonce,
    );

    return EncryptedMessage(
      content: hex.encode(secretBox.cipherText),
      nonce: hex.encode(secretBox.nonce),
      mac: hex.encode(secretBox.mac.bytes),
    );
  }
  Future<String> decryptMessage({
    required SecretKey sharedKey,
    required EncryptedMessage encryptedMessage,
  }) async {
    final secretBox = SecretBox(
      hex.decode(encryptedMessage.content),
      nonce: hex.decode(encryptedMessage.nonce),
      mac: Mac(hex.decode(encryptedMessage.mac)),
    );

    final clearText = await cipher.decrypt(
      secretBox,
      secretKey: sharedKey,
    );

    return String.fromCharCodes(clearText);
  }
}