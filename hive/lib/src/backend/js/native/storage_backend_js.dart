import 'dart:async';
import 'dart:typed_data';

import 'package:hive/hive.dart';
import 'package:hive/src/backend/storage_backend.dart';
import 'package:hive/src/binary/binary_reader_impl.dart';
import 'package:hive/src/binary/binary_writer_impl.dart';
import 'package:hive/src/binary/frame.dart';
import 'package:hive/src/box/keystore.dart';
import 'package:hive/src/registry/type_registry_impl.dart';
import 'package:idb_shim/idb.dart';

/// Handles all IndexedDB related tasks using idb_shim
class StorageBackendJs extends StorageBackend {
  static const _bytePrefix = [0x90, 0xA9];
  final Database _db;
  final HiveCipher? _cipher;
  final String objectStoreName;

  TypeRegistry _registry;

  StorageBackendJs(this._db, this._cipher, this.objectStoreName,
      [this._registry = TypeRegistryImpl.nullImpl]);

  @override
  String? get path => null;

  @override
  bool supportsCompaction = false;

  bool _isEncoded(Uint8List bytes) {
    return bytes.length >= _bytePrefix.length &&
        bytes[0] == _bytePrefix[0] &&
        bytes[1] == _bytePrefix[1];
  }

  Future<dynamic> encodeValue(Frame frame) async {
    var value = frame.value;
    if (_cipher == null) {
      if (value == null) return value;
      if (value is Uint8List && !_isEncoded(value)) return value.buffer;
      if (value is num || value is bool || value is String) return value;
    }

    var frameWriter = BinaryWriterImpl(_registry);
    frameWriter.writeByteList(_bytePrefix, writeLength: false);

    _cipher == null
        ? frameWriter.write(value)
        : await frameWriter.writeEncrypted(value, _cipher!);

    var bytes = frameWriter.toBytes();
    return bytes.buffer;
  }

  Future<dynamic> decodeValue(dynamic value) async {
    if (value is ByteBuffer) {
      var bytes = Uint8List.view(value);
      if (_isEncoded(bytes)) {
        var reader = BinaryReaderImpl(bytes, _registry);
        reader.skip(2);
        return _cipher == null ? reader.read() : reader.readEncrypted(_cipher!);
      }
      return bytes;
    }
    return value;
  }

  ObjectStore getStore(bool write) {
    return _db
        .transaction(objectStoreName, write ? 'readwrite' : 'readonly')
        .objectStore(objectStoreName);
  }

  Future<List<dynamic>> getKeys() async {
    var store = getStore(false);
    return (await store.getAllKeys());
  }

  Future<Iterable<dynamic>> getValues() async {
    var store = getStore(false);
    var result = await store.getAll();
    return Future.wait(result.map(decodeValue));
  }

  @override
  Future<int> initialize(
      TypeRegistry registry, Keystore keystore, bool lazy) async {
    _registry = registry;
    var keys = await getKeys();
    if (!lazy) {
      var values = await getValues();
      for (var i = 0; i < values.length; i++) {
        keystore.insert(Frame(keys[i], values.elementAt(i)), notify: false);
      }
    } else {
      for (var key in keys) {
        keystore.insert(Frame.lazy(key), notify: false);
      }
    }
    return 0;
  }

  @override
  Future<dynamic> readValue(Frame frame) async {
    var value = await getStore(false).getObject(frame.key);
    return decodeValue(value);
  }

  @override
  Future<void> writeFrames(List<Frame> frames) async {
    var store = getStore(true);
    for (var frame in frames) {
      frame.deleted
          ? await store.delete(frame.key)
          : await store.put(await encodeValue(frame), frame.key);
    }
  }

  @override
  Future<List<Frame>> compact(Iterable<Frame> frames) =>
      throw UnsupportedError('Not supported');

  @override
  Future<void> clear() => getStore(true).clear();

  @override
  Future<void> close() async => _db.close();

  @override
  Future<void> deleteFromDisk() async {
    final dbName = _db.name;
    await _db.factory.deleteDatabase(dbName);
  }

  @override
  Future<void> flush() => Future.value();
}
