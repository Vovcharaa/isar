import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:isar/isar.dart';
import 'package:isar/src/native/isar_core.dart';

import 'binary_reader.dart';
import 'bindings.dart';
import 'index_key.dart';
import 'isar_impl.dart';
import 'query_build.dart';

class IsarCollectionImpl<OBJ> extends IsarCollection<OBJ> {
  @override
  final IsarImpl isar;
  final Pointer<CIsarCollection> ptr;

  final CollectionSchema<OBJ> schema;
  final int _staticSize;
  final List<int> _offsets;

  IsarCollectionImpl({
    required this.isar,
    required this.ptr,
    required this.schema,
    required int staticSize,
    required List<int> offsets,
  })  : _staticSize = staticSize,
        _offsets = offsets;

  @override
  String get name => schema.name;

  @pragma('vm:prefer-inline')
  OBJ deserializeObject(CObject cObj) {
    final buffer = cObj.buffer.asTypedList(cObj.buffer_length);
    final reader = BinaryReader(buffer);
    return schema.deserializeNative(this, cObj.id, reader, _offsets);
  }

  @pragma('vm:prefer-inline')
  OBJ? deserializeObjectOrNull(CObject cObj) {
    if (!cObj.buffer.isNull) {
      return deserializeObject(cObj);
    } else {
      return null;
    }
  }

  @pragma('vm:prefer-inline')
  List<OBJ> deserializeObjects(CObjectSet objectSet) {
    final objects = <OBJ>[];
    for (var i = 0; i < objectSet.length; i++) {
      final cObjPtr = objectSet.objects.elementAt(i);
      final object = deserializeObject(cObjPtr.ref);
      objects.add(object);
    }
    return objects;
  }

  @pragma('vm:prefer-inline')
  List<OBJ?> deserializeObjectsOrNull(CObjectSet objectSet) {
    final objects = List<OBJ?>.filled(objectSet.length, null);
    for (var i = 0; i < objectSet.length; i++) {
      final cObj = objectSet.objects.elementAt(i).ref;
      if (!cObj.buffer.isNull) {
        objects[i] = deserializeObject(cObj);
      }
    }
    return objects;
  }

  @pragma('vm:prefer-inline')
  Pointer<Pointer<CIndexKey>> _getKeysPtr(
      String indexName, List<List<Object?>> values, Allocator alloc) {
    final keysPtrPtr = alloc<Pointer<CIndexKey>>(values.length);
    for (var i = 0; i < values.length; i++) {
      keysPtrPtr[i] = buildIndexKey(schema, indexName, values[i]);
    }
    return keysPtrPtr;
  }

  List<T> deserializeProperty<T>(CObjectSet objectSet, int propertyIndex) {
    final values = <T>[];
    final propertyOffset = _offsets[propertyIndex];
    for (var i = 0; i < objectSet.length; i++) {
      final cObj = objectSet.objects.elementAt(i).ref;
      final buffer = cObj.buffer.asTypedList(cObj.buffer_length);
      values.add(schema.deserializePropNative(
        cObj.id,
        BinaryReader(buffer),
        propertyIndex,
        propertyOffset,
      ));
    }
    return values;
  }

  @override
  Future<OBJ?> get(int id) => getAll([id]).then((objects) => objects[0]);

  @override
  Future<List<OBJ?>> getAll(List<int> ids) {
    return isar.getTxn(false, (txn) async {
      final cObjSetPtr = txn.allocRawObjSet(ids.length);
      final objectsPtr = cObjSetPtr.ref.objects;
      for (var i = 0; i < ids.length; i++) {
        objectsPtr.elementAt(i).ref.id = ids[i];
      }
      IC.isar_get_all(ptr, txn.ptr, cObjSetPtr);
      await txn.wait();
      return deserializeObjectsOrNull(cObjSetPtr.ref);
    });
  }

  @override
  OBJ? getSync(int id) => getAllSync([id])[0];

  @override
  List<OBJ?> getAllSync(List<int> ids) {
    return isar.getTxnSync(false, (txn) {
      final cObjPtr = txn.allocCObject();
      final cObj = cObjPtr.ref;

      final objects = List<OBJ?>.filled(ids.length, null);
      for (var i = 0; i < ids.length; i++) {
        cObj.id = ids[i];
        nCall(IC.isar_get(ptr, txn.ptr, cObjPtr));
        objects[i] = deserializeObjectOrNull(cObj);
      }

      return objects;
    });
  }

  @override
  Future<OBJ?> getByIndex(
    String indexName,
    List<Object?> key,
  ) =>
      getAllByIndex(indexName, [key]).then((objects) => objects[0]);

  @override
  Future<List<OBJ?>> getAllByIndex(String indexName, List<List<Object?>> keys) {
    return isar.getTxn(false, (txn) async {
      final cObjSetPtr = txn.allocRawObjSet(keys.length);
      final keysPtrPtr = _getKeysPtr(indexName, keys, txn.alloc);
      IC.isar_get_all_by_index(
          ptr, txn.ptr, schema.indexIdOrErr(indexName), keysPtrPtr, cObjSetPtr);
      await txn.wait();
      return deserializeObjectsOrNull(cObjSetPtr.ref);
    });
  }

  @override
  OBJ? getByIndexSync(
    String indexName,
    List<Object?> key,
  ) =>
      getAllByIndexSync(indexName, [key])[0];

  @override
  List<OBJ?> getAllByIndexSync(String indexName, List<List<Object?>> keys) {
    return isar.getTxnSync(false, (txn) {
      final cObjPtr = txn.allocCObject();
      final cObj = cObjPtr.ref;
      final indexId = schema.indexIdOrErr(indexName);

      final objects = List<OBJ?>.filled(keys.length, null);
      for (var i = 0; i < keys.length; i++) {
        final keyPtr = buildIndexKey(schema, indexName, keys[i]);
        nCall(IC.isar_get_by_index(ptr, txn.ptr, indexId, keyPtr, cObjPtr));
        objects[i] = deserializeObjectOrNull(cObj);
      }

      return objects;
    });
  }

  @override
  Future<int> put(OBJ object, {bool saveLinks = false}) {
    return putAll([object], saveLinks: saveLinks).then((ids) => ids[0]);
  }

  @override
  Future<List<int>> putAll(List<OBJ> objects, {bool saveLinks = false}) {
    return isar.getTxn(true, (txn) async {
      final cObjSetPtr = txn.allocRawObjSet(objects.length);
      final objectsPtr = cObjSetPtr.ref.objects;

      Pointer<Uint8> allocBuf(int size) => txn.alloc<Uint8>(size);
      for (var i = 0; i < objects.length; i++) {
        final object = objects[i];
        final cObj = objectsPtr.elementAt(i).ref;
        schema.serializeNative(
            this, cObj, object, _staticSize, _offsets, allocBuf);
        cObj.id = schema.getId(object) ?? Isar.autoIncrement;
      }
      IC.isar_put_all(ptr, txn.ptr, cObjSetPtr);

      await txn.wait();
      final cObjectSet = cObjSetPtr.ref;
      final ids = List<int>.filled(objects.length, 0);
      final linkFutures = <Future>[];
      for (var i = 0; i < objects.length; i++) {
        final cObjPtr = cObjectSet.objects.elementAt(i);
        final id = cObjPtr.ref.id;
        ids[i] = id;

        final object = objects[i];
        schema.setId?.call(object, id);

        if (schema.hasLinks) {
          schema.attachLinks(this, id, object);
          if (saveLinks) {
            for (var link in schema.getLinks(object)) {
              if (link.isChanged) {
                linkFutures.add(link.save());
              }
            }
          }
        }
      }
      if (linkFutures.isNotEmpty) {
        await Future.wait(linkFutures);
      }
      return ids;
    });
  }

  @override
  int putSync(OBJ object, {bool saveLinks = false}) {
    return putAllSync([object], saveLinks: saveLinks)[0];
  }

  @override
  List<int> putAllSync(List<OBJ> objects, {bool saveLinks = false}) {
    return isar.getTxnSync(true, (txn) {
      final cObjPtr = txn.allocCObject();
      final cObj = cObjPtr.ref;

      final ids = List<int>.filled(objects.length, 0);
      for (var i = 0; i < objects.length; i++) {
        final object = objects[i];
        schema.serializeNative(
            this, cObj, object, _staticSize, _offsets, txn.allocBuffer);
        cObj.id = schema.getId(object) ?? Isar.autoIncrement;
        nCall(IC.isar_put(ptr, txn.ptr, cObjPtr));

        final id = cObj.id;
        ids[i] = id;
        schema.setId?.call(object, id);

        if (schema.hasLinks) {
          schema.attachLinks(this, id, object);
          if (saveLinks) {
            for (var link in schema.getLinks(object)) {
              if (link.isChanged) {
                link.saveSync();
              }
            }
          }
        }
      }
      return ids;
    });
  }

  @override
  Future<bool> delete(int id) => deleteAll([id]).then((count) => count == 1);

  @override
  Future<int> deleteAll(List<int> ids) {
    return isar.getTxn(true, (txn) async {
      final countPtr = txn.alloc<Uint32>();
      final idsPtr = txn.alloc<Int64>(ids.length);
      idsPtr.asTypedList(ids.length).setAll(0, ids);

      IC.isar_delete_all(ptr, txn.ptr, idsPtr, ids.length, countPtr);
      await txn.wait();

      return countPtr.value;
    });
  }

  @override
  bool deleteSync(int id) => deleteAllSync([id]) == 1;

  @override
  int deleteAllSync(List<int> ids) {
    return isar.getTxnSync(true, (txn) {
      final deletedPtr = txn.allocBuffer(1);

      var counter = 0;
      for (var id in ids) {
        nCall(IC.isar_delete(ptr, txn.ptr, id, deletedPtr));
        if (deletedPtr.value == 1) {
          counter++;
        }
      }
      return counter;
    });
  }

  @override
  Future<bool> deleteByIndex(String indexName, List<Object?> key) =>
      deleteAllByIndex(indexName, [key]).then((count) => count == 1);

  @override
  Future<int> deleteAllByIndex(String indexName, List<List<Object?>> keys) {
    return isar.getTxn(true, (txn) async {
      final countPtr = txn.alloc<Uint32>();
      final keysPtrPtr = _getKeysPtr(indexName, keys, txn.alloc);

      IC.isar_delete_all_by_index(ptr, txn.ptr, schema.indexIdOrErr(indexName),
          keysPtrPtr, keys.length, countPtr);
      await txn.wait();

      return countPtr.value;
    });
  }

  @override
  bool deleteByIndexSync(String indexName, List<Object?> key) =>
      deleteAllByIndexSync(indexName, [key]) == 1;

  @override
  int deleteAllByIndexSync(String indexName, List<List<Object?>> keys) {
    return isar.getTxnSync(true, (txn) {
      final countPtr = txn.alloc<Uint32>();
      final keysPtrPtr = _getKeysPtr(indexName, keys, txn.alloc);

      nCall(IC.isar_delete_all_by_index(ptr, txn.ptr,
          schema.indexIdOrErr(indexName), keysPtrPtr, keys.length, countPtr));
      return countPtr.value;
    });
  }

  @override
  Future<void> clear() {
    return isar.getTxn(true, (txn) async {
      IC.isar_clear(ptr, txn.ptr);
      await txn.wait();
    });
  }

  @override
  void clearSync() {
    isar.getTxnSync(true, (txn) {
      nCall(IC.isar_clear(ptr, txn.ptr));
    });
  }

  @override
  Future<void> importJson(List<Map<String, dynamic>> json) {
    final bytes = Utf8Encoder().convert(jsonEncode(json));
    return importJsonRaw(bytes);
  }

  @override
  Future<void> importJsonRaw(Uint8List jsonBytes) {
    return isar.getTxn(true, (txn) async {
      final bytesPtr = txn.alloc<Uint8>(jsonBytes.length);
      bytesPtr.asTypedList(jsonBytes.length).setAll(0, jsonBytes);
      final idNamePtr = schema.idName.toNativeUtf8(allocator: txn.alloc);

      IC.isar_json_import(
          ptr, txn.ptr, idNamePtr.cast(), bytesPtr, jsonBytes.length);
      await txn.wait();
    });
  }

  @override
  void importJsonSync(List<Map<String, dynamic>> json) {
    final bytes = Utf8Encoder().convert(jsonEncode(json));
    importJsonRawSync(bytes);
  }

  @override
  void importJsonRawSync(Uint8List jsonBytes) {
    return isar.getTxnSync(true, (txn) async {
      final bytesPtr = txn.allocBuffer(jsonBytes.length);
      bytesPtr.asTypedList(jsonBytes.length).setAll(0, jsonBytes);
      final idNamePtr = schema.idName.toNativeUtf8(allocator: txn.alloc);

      nCall(IC.isar_json_import(
          ptr, txn.ptr, idNamePtr.cast(), bytesPtr, jsonBytes.length));
    });
  }

  @override
  Stream<void> watchLazy() {
    // ignore: invalid_use_of_protected_member
    isar.requireOpen();
    final port = ReceivePort();
    final handle =
        IC.isar_watch_collection(isar.ptr, ptr, port.sendPort.nativePort);
    final controller = StreamController(onCancel: () {
      IC.isar_stop_watching(handle);
    });
    controller.addStream(port);
    return controller.stream;
  }

  @override
  Stream<OBJ?> watchObject(int id, {bool initialReturn = false}) {
    return watchObjectLazy(id, initialReturn: initialReturn)
        .asyncMap((event) => get(id));
  }

  @override
  Stream<void> watchObjectLazy(int id, {bool initialReturn = false}) {
    // ignore: invalid_use_of_protected_member
    isar.requireOpen();
    final cObjPtr = malloc<CObject>();

    final port = ReceivePort();
    final handle =
        IC.isar_watch_object(isar.ptr, ptr, id, port.sendPort.nativePort);
    malloc.free(cObjPtr);

    final controller = StreamController(onCancel: () {
      IC.isar_stop_watching(handle);
    });

    if (initialReturn) {
      controller.add(true);
    }

    controller.addStream(port);
    return controller.stream;
  }

  @override
  Query<T> buildQuery<T>({
    List<WhereClause> whereClauses = const [],
    bool whereDistinct = false,
    Sort whereSort = Sort.asc,
    FilterOperation? filter,
    List<SortProperty> sortBy = const [],
    List<DistinctProperty> distinctBy = const [],
    int? offset,
    int? limit,
    String? property,
  }) {
    // ignore: invalid_use_of_protected_member
    isar.requireOpen();
    return buildNativeQuery(
      this,
      whereClauses,
      whereDistinct,
      whereSort,
      filter,
      sortBy,
      distinctBy,
      offset,
      limit,
      property,
    );
  }
}
