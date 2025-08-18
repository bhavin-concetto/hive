import 'dart:async';
import 'dart:js_interop';

import 'package:hive/hive.dart';
import 'package:hive/src/backend/js/native/storage_backend_js.dart';
import 'package:hive/src/backend/storage_backend.dart';
import 'package:idb_shim/idb.dart';

/// Opens IndexedDB databases
class BackendManager implements BackendManagerInterface {
  @JS('window.indexedDB')
  external IdbFactory? get windowIndexedDB;

  @JS('self.indexedDB')
  external IdbFactory? get workerIndexedDB;

  IdbFactory? get indexedDB => windowIndexedDB ?? workerIndexedDB;

  @override
  Future<StorageBackend> open(String name, String? path, bool crashRecovery,
      HiveCipher? cipher, String? collection) async {
    // compatibility for old store format
    final databaseName = collection ?? name;
    final objectStoreName = collection == null ? 'box' : name;

    var db = await indexedDB!.open(databaseName, version: 1,
        onUpgradeNeeded: (VersionChangeEvent e) {
      var db = e.database;
      if (!(db.objectStoreNames).contains(objectStoreName)) {
        db.createObjectStore(objectStoreName);
      }
    });

    // in case the objectStore is not contained, re-open the db and
    // update version
    if (!(db.objectStoreNames).contains(objectStoreName)) {
      db = await indexedDB!.open(
        databaseName,
        version: (db.version) + 1,
        onUpgradeNeeded: (e) {
          var db = e.target as Database;
          if (!(db.objectStoreNames).contains(objectStoreName)) {
            db.createObjectStore(objectStoreName);
          }
        },
      );
    }

    return StorageBackendJs(db, cipher, objectStoreName);
  }

  @override
  Future<Map<String, StorageBackend>> openCollection(
      Set<String> names,
      String? path,
      bool crashRecovery,
      HiveCipher? cipher,
      String collection) async {
    var db =
        await indexedDB!.open(collection, version: 1, onUpgradeNeeded: (e) {
      var db = e.target as Database;
      for (var objectStoreName in names) {
        if (!(db.objectStoreNames).contains(objectStoreName)) {
          db.createObjectStore(objectStoreName);
        }
      }
    });

    // in case the objectStore is not contained, re-open the db and
    // update version
    if (!(names.every((objectStoreName) =>
        (db.objectStoreNames).contains(objectStoreName)))) {
      db = await indexedDB!.open(
        collection,
        version: (db.version) + 1,
        onUpgradeNeeded: (e) {
          var db = e.target as Database;
          for (var objectStoreName in names) {
            if (!(db.objectStoreNames).contains(objectStoreName)) {
              db.createObjectStore(objectStoreName);
            }
          }
        },
      );
    }
    return Map.fromEntries(
        names.map((e) => MapEntry(e, StorageBackendJs(db, cipher, e))));
  }

  @override
  Future<void> deleteBox(String name, String? path, String? collection) async {
    // compatibility for old store format
    final databaseName = collection ?? name;
    final objectStoreName = collection == null ? 'box' : name;

    // directly deleting the entire DB if a non-collection Box
    if (collection == null) {
      await indexedDB!.deleteDatabase(databaseName);
    } else {
      final db =
          await indexedDB!.open(databaseName, version: 1, onUpgradeNeeded: (e) {
        var db = e.target as Database;
        if ((db.objectStoreNames).contains(objectStoreName)) {
          db.deleteObjectStore(objectStoreName);
        }
      });
      if ((db.objectStoreNames).isEmpty) {
        indexedDB!.deleteDatabase(databaseName);
      }
    }
  }

  @override
  Future<bool> boxExists(String name, String? path, String? collection) async {
    // compatibility for old store format
    final databaseName = collection ?? name;
    final objectStoreName = collection == null ? 'box' : name;
    // https://stackoverflow.com/a/17473952
    try {
      var exists = true;
      if (collection == null) {
        await indexedDB!.open(databaseName, version: 1, onUpgradeNeeded: (e) {
          final db = e.target as Database;
          db.transaction(db.objectStoreNames, 'idbModeReadWrite').abort();
          exists = false;
        });
      } else {
        final db =
            await indexedDB!.open(collection, version: 1, onUpgradeNeeded: (e) {
          var db = e.target as Database;
          exists = (db.objectStoreNames).contains(objectStoreName);
        });
        exists = (db.objectStoreNames).contains(objectStoreName);
      }
      return exists;
    } catch (error) {
      return false;
    }
  }
}
