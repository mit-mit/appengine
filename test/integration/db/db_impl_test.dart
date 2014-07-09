// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library db_impl_test;

import 'dart:async';

import 'package:unittest/unittest.dart';

import 'package:cloud_datastore/cloud_datastore.dart' as db;
import 'package:appengine/src/appengine_context.dart';
import 'package:appengine/src/api_impl/raw_datastore_v3_impl.dart';
import 'package:appengine/src/protobuf_api/rpc/rpc_service_remote_api.dart';

@db.ModelMetadata(const PersonDesc())
class Person extends db.Model {
  String name;
  int age;
  db.Key wife;

  operator==(Object other) => sameAs(other);

  sameAs(Object other) {
    return other is Person &&
        id == other.id &&
        parentKey == other.parentKey &&
        name == other.name &&
        age == other.age &&
        wife == other.wife;
  }
}

@db.ModelMetadata(const UserDesc())
class User extends Person {
  String nickname;
  List<String> languages = const [];

  sameAs(Object other) {
    if (!(super.sameAs(other) && other is User && nickname == other.nickname))
      return false;

    User user = other;
    if (languages == null) {
      if (user.languages == null) return true;
      return false;
    }
    if (languages.length != user.languages.length) {
      return false;
    }

    for (int i = 0; i < languages.length; i++) {
      if (languages[i] != user.languages[i]) {
        return false;
      }
    }
    return true;
  }
}

class PersonDesc extends db.ModelDescription {
  final id = const db.IntProperty();
  final name = const db.StringProperty();
  final age = const db.IntProperty();
  final wife = const db.ModelKeyProperty();

  const PersonDesc({String kind: 'Person'}) : super(kind);
}

class UserDesc extends PersonDesc {
  final nickname = const db.StringProperty();
  final languages =
      const db.StringListProperty(propertyName: 'language');
  const UserDesc({String kind: 'User'}) : super(kind: kind);
}


@db.ModelMetadata(const PolyPersonDesc())
class PolyPerson extends db.PolyModel {
  String name;

  // NOTE: There is no need to store these values, we make these two an alias
  // for [name]. They are only used for querying.
  String get indexedName => name;
  String get unIndexedName => name;
  set indexedName(String newName) => name = newName;
  set unIndexedName(String newName) => name = newName;

  operator==(Object other) => isSame(other);

  isSame(Object other) {
    return
        other is PolyPerson &&
        id == other.id &&
        name == other.name;
  }
}

@db.ModelMetadata(const PolyUserDesc())
class PolyUser extends PolyPerson {
  String nickname;

  isSame(Object other) =>
      super.isSame(other) && other is PolyUser && nickname == other.nickname;
}

class PolyPersonDesc extends db.PolyModelDescription {
  static String PolyModelName = 'PolyPerson';

  final id = const db.IntProperty();
  final name = const db.StringProperty();
  final indexedName = const db.StringProperty(indexed: true);
  final unIndexedName = const db.StringProperty(indexed: false);

  const PolyPersonDesc() : super();
}

class PolyUserDesc extends PolyPersonDesc {
  static String PolyModelName = 'PolyUser';

  final nickname = const db.StringProperty();
  const PolyUserDesc();
}


@db.ModelMetadata(const ExpandoPersonDesc())
class ExpandoPerson extends db.ExpandoModel {
  String name;
  String nickname;

  operator==(Object other) {
    if (other is ExpandoPerson && id == other.id && name == other.name) {
      if (additionalProperties.length != other.additionalProperties.length) {
        return false;
      }
      for (var key in additionalProperties.keys) {
        if (additionalProperties[key] != other.additionalProperties[key]) {
          return false;
        }
      }
      return true;
    }
    return false;
  }
}

class ExpandoPersonDesc extends db.ExpandoModelDescription {
  final id = const db.IntProperty();
  final name = const db.StringProperty();
  final nickname = const db.StringProperty(propertyName: 'NN');

  const ExpandoPersonDesc() : super('ExpandoPerson');
}


Future sleep(Duration duration) {
  var completer = new Completer();
  new Timer(duration, completer.complete);
  return completer.future;
}

runTests(db.DatastoreDB store) {
  void compareModels(List<db.Model> expectedModels,
                     List<db.Model> models,
                     {bool anyOrder: false}) {
    expect(models.length, equals(expectedModels.length));
    if (anyOrder) {
      // Do expensive O(n^2) search.
      for (var searchModel in expectedModels) {
        bool found = false;
        for (var m in models) {
          if (m == searchModel) {
            found = true;
            break;
          }
        }
        expect(found, isTrue);
      }
    } else {
      for (var i = 0; i < expectedModels.length; i++) {
        expect(models[i], equals(expectedModels[i]));
      }
    }
  }

  Future testInsertLookupDelete(
      List<db.Model> objects, {bool transactional: false, bool xg: false}) {
    var keys = objects.map((db.Model obj) => obj.key).toList();

    if (transactional) {
      return store.beginTransaction(crossEntityGroup: xg)
          .then((db.Transaction commitTransaction) {
        commitTransaction.queueMutations(inserts: objects);
        return commitTransaction.commit().then((_) {
          return store.beginTransaction(crossEntityGroup: xg)
              .then((db.Transaction deleteTransaction) {
            return deleteTransaction.lookup(keys).then((List<db.Model> models) {
              compareModels(objects, models);
              deleteTransaction.queueMutations(deletes: keys);
              return deleteTransaction.commit();
            });
          });
        });
      });
    } else {
      return store.commit(inserts: objects).then(expectAsync((_) {
        return store.lookup(keys).then(expectAsync((List<db.Model> models) {
          compareModels(objects, models);
          return store.commit(deletes: keys).then(expectAsync((_) {
            return store.lookup(keys).then(expectAsync((List<db.Model> models) {
              for (var i = 0; i < models.length; i++) {
                expect(models[i], isNull);
              }
            }));
          }));
        }));
      }));
    }
  }

  group('key', () {
    test('equal_and_hashcode', () {
      var k1 = store.emptyKey.append(User, id: 10).append(Person, id: 12);
      var k2 = store.newPartition(null)
          .emptyKey.append(User, id: 10).append(Person, id: 12);
      expect(k1, equals(k2));
      expect(k1.hashCode, equals(k2.hashCode));
    });
  });

  group('db', () {
    group('insert_lookup_delete', () {
      test('persons', () {
        var root = store.emptyKey;
        var persons = [];
        for (var i = 1; i <= 10; i++) {
          persons.add(new Person()
              ..id = i
              ..parentKey = root
              ..age = 42 + i
              ..name = 'user$i');
        }
        persons.first.wife = persons.last.key;
        return testInsertLookupDelete(persons);
      });
      test('users', () {
        var root = store.emptyKey;
        var users = [];
        for (var i = 1; i <= 10; i++) {
          users.add(new User()
              ..id = i
              ..parentKey = root
              ..age = 42 + i
              ..name = 'user$i'
              ..nickname = 'nickname${i%3}');
        }
        return testInsertLookupDelete(users);
      });
      test('poly_insert', () {
        var root = store.emptyKey;
        var persons = [];
        for (var i = 1; i <= 10; i++) {
          persons.add(new PolyPerson()
              ..id = i
              ..parentKey = root
              ..name = 'user$i');
        }
        for (var i = 11; i <= 20; i++) {
          persons.add(new PolyUser()
              ..id = i
              ..parentKey = root
              ..name = 'user$i'
              ..nickname = 'nickname${i%3}');
        }
        return testInsertLookupDelete(persons);
      });
      test('expando_insert', () {
        var root = store.emptyKey;
        var expandoPersons = [];
        for (var i = 1; i <= 10; i++) {
          var expandoPerson = new ExpandoPerson()
              ..parentKey = root
              ..id = i
              ..name = 'user$i';
          expandoPerson.foo = 'foo$i';
          expandoPerson.bar = i;
          expect(expandoPerson.additionalProperties['foo'], equals('foo$i'));
          expect(expandoPerson.additionalProperties['bar'], equals(i));
          expandoPersons.add(expandoPerson);
        }
        return testInsertLookupDelete(expandoPersons);
      });
      test('transactional_insert', () {
        var root = store.emptyKey;
        var models = [];

        models.add(new Person()
            ..id = 1
            ..parentKey = root
            ..age = 1
            ..name = 'user1');
        models.add(new User()
            ..id = 2
            ..parentKey = root
            ..age = 2
            ..name = 'user2'
            ..nickname = 'nickname2');
        models.add(new PolyPerson()
            ..id = 3
            ..parentKey = root
            ..name = 'user3');
        models.add(new PolyUser()
            ..id = 4
            ..parentKey = root
            ..name = 'user4'
            ..nickname = 'nickname4');
        var expandoPerson = new ExpandoPerson()
            ..parentKey = root
            ..id = 3
            ..name = 'user1';
        expandoPerson.foo = 'foo1';
        expandoPerson.bar = 2;

        return testInsertLookupDelete(models, transactional: true, xg: true);
      });

      test('parent_key', () {
        var root = store.emptyKey;
        var users = [];
        for (var i = 333; i <= 334; i++) {
          users.add(new User()
              ..id = i
              ..parentKey = root
              ..age = 42 + i
              ..name = 'user$i'
              ..nickname = 'nickname${i%3}');
        }
        var persons = [];
        for (var i = 335; i <= 336; i++) {
          persons.add(new Person()
              ..id = i
              ..parentKey = root
              ..age = 42 + i
              ..name = 'person$i');
        }

        // We test that we can insert + lookup
        // users[0], (persons[0] + users[0] as parent)
        // persons[1], (users[1] + persons[0] as parent)
        persons[0].parentKey = users[0].key;
        users[1].parentKey = persons[1].key;

        return testInsertLookupDelete([]..addAll(users)..addAll(persons));
      });

      test('auto_ids', () {
        var root = store.emptyKey;
        var persons = [];
        persons.add(new Person()
            ..id = 42
            ..parentKey = root
            ..age = 80
            ..name = 'user80');
        // Auto id person with parentKey
        persons.add(new Person()
            ..parentKey = root
            ..age = 81
            ..name = 'user81');
        // Auto id person without parentKey
        persons.add(new Person()
            ..age = 82
            ..name = 'user82');
        // Auto id person with non-root parentKey
        var fatherKey = persons.first.parentKey;
        persons.add(new Person()
            ..parentKey = fatherKey
            ..age = 83
            ..name = 'user83');
        persons.add(new Person()
            ..id = 43
            ..parentKey = root
            ..age = 84
            ..name = 'user84');
        return store.commit(inserts: persons).then(expectAsync((_) {
          // At this point, autoIds are allocated and are relfected in the
          // models (as well as parentKey if it was empty).

          var keys = persons.map((db.Model obj) => obj.key).toList();

          for (var i = 0; i < persons.length; i++) {
            expect(persons[i].age, equals(80 + i));
            expect(persons[i].name, equals('user${80 + i}'));
          }

          expect(persons[0].id, equals(42));
          expect(persons[0].parentKey, equals(root));

          expect(persons[1].id, isNotNull);
          expect(persons[1].id is int, isTrue);
          expect(persons[1].parentKey, equals(root));

          expect(persons[2].id, isNotNull);
          expect(persons[2].id is int, isTrue);
          expect(persons[2].parentKey, equals(root));

          expect(persons[3].id, isNotNull);
          expect(persons[3].id is int, isTrue);
          expect(persons[3].parentKey, equals(fatherKey));

          expect(persons[4].id, equals(43));
          expect(persons[4].parentKey, equals(root));

          expect(persons[1].id != persons[2].id, isTrue);
          // NOTE: We can't make assumptions about the id of persons[3],
          // because an id doesn't need to be globally unique, only under
          // entities with the same parent.

          return store.lookup(keys).then(expectAsync((List<Person> models) {
            // Since the id/parentKey fields are set after commit and a lookup
            // returns new model instances, we can do full model comparision
            // here.
            compareModels(persons, models);
            return store.commit(deletes: keys).then(expectAsync((_) {
              return store.lookup(keys).then(expectAsync((List models) {
                for (var i = 0; i < models.length; i++) {
                  expect(models[i], isNull);
                }
              }));
            }));
          }));
        }));
      });
    });

    test('query', () {
      var root = store.emptyKey;
      var users = [];
      for (var i = 1; i <= 10; i++) {
        var languages = [];
        if (i == 10) {
          languages = ['foo'];
        } else if (i == 10) {
          languages = ['foo', 'bar'];
        }
        users.add(new User()
            ..id = i
            ..parentKey = root
            ..age = 42 + i
            ..name = 'user$i'
            ..nickname = 'nickname${i%3}'
            ..languages = languages);
      }

      var polyPersons = [];
      var polyUsers = [];
      for (var i = 1; i <= 10; i++) {
        polyPersons.add(new PolyPerson()
            ..id = i
            ..parentKey = root
            ..name = 'person$i');
      }
      for (var i = 11; i <= 20; i++) {
        polyPersons.add(new PolyUser()
            ..id = i
            ..parentKey = root
            ..name = 'user$i'
            ..nickname = 'nickname${i%3}');
        polyUsers.add(polyPersons.last);
      }
      var sortedPolyPersons = []
          ..addAll(polyPersons)
          ..sort((a, b) => a.name.compareTo(b.name));

      var expandoPersons = [];
      for (var i = 1; i <= 3; i++) {
        var expandoPerson = new ExpandoPerson()
            ..parentKey = root
            ..id = i
            ..name = 'user$i'
            ..nickname = 'nickuser$i';
        expandoPerson.foo = 'foo$i';
        expandoPerson.bar = i;
        expect(expandoPerson.additionalProperties['foo'], equals('foo$i'));
        expect(expandoPerson.additionalProperties['bar'], equals(i));
        expandoPersons.add(expandoPerson);
      }

      var LOWER_BOUND = 'user2';

      var usersSortedNameDescNicknameAsc = new List.from(users);
      usersSortedNameDescNicknameAsc.sort((User a, User b) {
        var result = b.name.compareTo(b.name);
        if (result == 0) return a.nickname.compareTo(b.nickname);
        return result;
      });

      var usersSortedNameDescNicknameDesc = new List.from(users);
      usersSortedNameDescNicknameDesc.sort((User a, User b) {
        var result = b.name.compareTo(b.name);
        if (result == 0) return b.nickname.compareTo(a.nickname);
        return result;
      });

      var usersSortedAndFilteredNameDescNicknameAsc =
          usersSortedNameDescNicknameAsc.where((User u) {
        return LOWER_BOUND.compareTo(u.name) <= 0;
      }).toList();

      var usersSortedAndFilteredNameDescNicknameDesc =
          usersSortedNameDescNicknameDesc.where((User u) {
        return LOWER_BOUND.compareTo(u.name) <= 0;
      }).toList();

      var fooUsers = users.where(
          (User u) => u.languages.contains('foo')).toList();
      var barUsers = users.where(
          (User u) => u.languages.contains('bar')).toList();

      // Note:
      // Non-ancestor queries (i.e. queries not lookups) result in index scans.
      // The index tables are updated in a "eventually consistent" way.
      //
      // So this can make tests flaky, if the index updates take longer than the
      // following constant.
      var INDEX_UPDATE_DELAY = const Duration(milliseconds: 900);

      var allInserts = []
          ..addAll(users)
          ..addAll(polyPersons)
          ..addAll(expandoPersons);
      var allKeys = allInserts.map((db.Model model) => model.key).toList();
      return store.commit(inserts: allInserts).then((_) {
        return sleep(INDEX_UPDATE_DELAY).then((_) {
          var tests = [
            // Queries for [Person] return no results, we only have [User]
            // objects.
            () {
              return store.query(Person).run().then((List<db.Model> models) {
                compareModels([], models);
              });
            },

            // All users query
            () {
              return store.query(User).run().then((List<db.Model> models) {
                compareModels(users, models, anyOrder: true);
              });
            },

            // Sorted query
            () {
              return store.query(User)
                  ..order('-name')
                  ..order('nickname')
                  ..run().then((List<db.Model> models) {
                compareModels(
                    usersSortedNameDescNicknameAsc, models, anyOrder: true);
              });
            },
            () {
              return store.query(User)
                  ..order('-name')
                  ..order('-nickname')
                  ..run().then((List<db.Model> models) {
                compareModels(
                    usersSortedNameDescNicknameDesc, models, anyOrder: true);
              });
            },

            // Sorted query with filter
            () {
              return store.query(User)
                  ..filter('name >=', LOWER_BOUND)
                  ..order('-name')
                  ..order('-nickname')
                  ..run().then((List<db.Model> models) {
                compareModels(usersSortedAndFilteredNameDescNicknameAsc,
                    models, anyOrder: true);
              });
            },
            () {
              return store.query(User)
                  ..filter('name >=', LOWER_BOUND)
                  ..order('name')
                  ..order('-nickname')
                  ..run().then((List<db.Model> models) {
                compareModels(usersSortedAndFilteredNameDescNicknameDesc,
                    models, anyOrder: true);
              });
            },

            // Filter lists
            () {
              return store.query(User)
                  ..filter('languages IN', ['foo'])
                  ..order('name')
                  ..run().then((List<db.Model> models) {
                compareModels(fooUsers, models, anyOrder: true);
              });
            },
            () {
              return store.query(User)
                  ..filter('languages IN', ['bar'])
                  ..order('name')
                  ..run().then((List<db.Model> models) {
                compareModels(barUsers, models, anyOrder: true);
              });
            },

            // PolyModel queries
            () {
              return store.query(PolyPerson)
                  ..run().then((List<db.Model> models) {
                // We compare here the query result in [models] to
                // *all* persons (i.e. [polyPersons] contains all Person and
                // User model objects)
                compareModels(polyPersons, models, anyOrder: true);
              });
            },
            () {
              return store.query(PolyUser)
                  ..run().then((List<db.Model> models) {
                // Here we ensure that [models] contains only Users.
                compareModels(polyUsers, models, anyOrder: true);
              });
            },

            // PolyModel indexed/unindexed queries
            () {
              return store.query(PolyPerson)
                  ..filter('indexedName =', 'person1')
                  ..run().then((List<db.Model> models) {
                compareModels([polyPersons[0]], models, anyOrder: true);
              });
            },
            () {
              return store.query(PolyPerson)
                  ..filter('unIndexedName =', 'person1')
                  ..run().then((List<db.Model> models) {
                compareModels([], models, anyOrder: true);
              });
            },

            // Simple limit/offset test.
            () {
              return store.query(PolyPerson)
                  ..order('name')
                  ..offset(3)
                  ..limit(10)
                  ..run().then((List<db.Model> models) {
                var expectedModels = sortedPolyPersons.sublist(3, 13);
                compareModels(expectedModels, models, anyOrder: true);
              });
            },

            // Expando queries: Filter on normal property.
            () {
              return store.query(ExpandoPerson)
                  ..filter('name =', expandoPersons.last.name)
                  ..run().then((List<db.Model> models) {
                compareModels([expandoPersons.last], models);
              });
            },
            // Expando queries: Filter on expanded String property
            () {
              return store.query(ExpandoPerson)
                  ..filter('foo =', expandoPersons.last.foo)
                  ..run().then((List<db.Model> models) {
                compareModels([expandoPersons.last], models);
              });
            },
            // Expando queries: Filter on expanded int property
            () {
              return store.query(ExpandoPerson)
                  ..filter('bar =', expandoPersons.last.bar)
                  ..run().then((List<db.Model> models) {
                compareModels([expandoPersons.last], models);
              });
            },
            // Expando queries: Filter normal property with different
            // propertyName (datastore name is 'NN').
            () {
              return store.query(ExpandoPerson)
                  ..filter('nickname =', expandoPersons.last.nickname)
                  ..run().then((List<db.Model> models) {
                compareModels([expandoPersons.last], models);
              });
            },

            // Delete results
            () => store.commit(deletes: allKeys),

            // Wait until the entity deletes are reflected in the indices.
            () => sleep(INDEX_UPDATE_DELAY),

            // Make sure queries don't return results
            () => store.lookup(allKeys).then((List<db.Model> models) {
              expect(models.length, equals(allKeys.length));
              for (var model in models) {
                expect(model, isNull);
              }
            }),
          ];
          return Future.forEach(tests, (f) => f());
        });
      });
    });
  });
}


void main() {
  var rpcService = new RPCServiceRemoteApi('127.0.0.1', 4444);
  var appengineContext = new AppengineContext(
      'dev', 'test-application', 'test-version', null, null, null);
  var datastore =
      new DatastoreV3RpcImpl(rpcService, appengineContext, '<invalid-ticket>');

  runTests(new db.DatastoreDB(datastore));
}
