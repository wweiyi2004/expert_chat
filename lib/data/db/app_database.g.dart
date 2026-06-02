// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $ConversationsTable extends Conversations
    with TableInfo<$ConversationsTable, Conversation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConversationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('新对话'),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _activeChildrenJsonMeta =
      const VerificationMeta('activeChildrenJson');
  @override
  late final GeneratedColumn<String> activeChildrenJson =
      GeneratedColumn<String>(
        'active_children_json',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    updatedAt,
    activeChildrenJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversations';
  @override
  VerificationContext validateIntegrity(
    Insertable<Conversation> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('active_children_json')) {
      context.handle(
        _activeChildrenJsonMeta,
        activeChildrenJson.isAcceptableOrUnknown(
          data['active_children_json']!,
          _activeChildrenJsonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Conversation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Conversation(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      activeChildrenJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}active_children_json'],
      ),
    );
  }

  @override
  $ConversationsTable createAlias(String alias) {
    return $ConversationsTable(attachedDatabase, alias);
  }
}

class Conversation extends DataClass implements Insertable<Conversation> {
  final String id;
  final String title;
  final DateTime updatedAt;
  final String? activeChildrenJson;
  const Conversation({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.activeChildrenJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || activeChildrenJson != null) {
      map['active_children_json'] = Variable<String>(activeChildrenJson);
    }
    return map;
  }

  ConversationsCompanion toCompanion(bool nullToAbsent) {
    return ConversationsCompanion(
      id: Value(id),
      title: Value(title),
      updatedAt: Value(updatedAt),
      activeChildrenJson: activeChildrenJson == null && nullToAbsent
          ? const Value.absent()
          : Value(activeChildrenJson),
    );
  }

  factory Conversation.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Conversation(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      activeChildrenJson: serializer.fromJson<String?>(
        json['activeChildrenJson'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'activeChildrenJson': serializer.toJson<String?>(activeChildrenJson),
    };
  }

  Conversation copyWith({
    String? id,
    String? title,
    DateTime? updatedAt,
    Value<String?> activeChildrenJson = const Value.absent(),
  }) => Conversation(
    id: id ?? this.id,
    title: title ?? this.title,
    updatedAt: updatedAt ?? this.updatedAt,
    activeChildrenJson: activeChildrenJson.present
        ? activeChildrenJson.value
        : this.activeChildrenJson,
  );
  Conversation copyWithCompanion(ConversationsCompanion data) {
    return Conversation(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      activeChildrenJson: data.activeChildrenJson.present
          ? data.activeChildrenJson.value
          : this.activeChildrenJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Conversation(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('activeChildrenJson: $activeChildrenJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, title, updatedAt, activeChildrenJson);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Conversation &&
          other.id == this.id &&
          other.title == this.title &&
          other.updatedAt == this.updatedAt &&
          other.activeChildrenJson == this.activeChildrenJson);
}

class ConversationsCompanion extends UpdateCompanion<Conversation> {
  final Value<String> id;
  final Value<String> title;
  final Value<DateTime> updatedAt;
  final Value<String?> activeChildrenJson;
  final Value<int> rowid;
  const ConversationsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.activeChildrenJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConversationsCompanion.insert({
    required String id,
    this.title = const Value.absent(),
    required DateTime updatedAt,
    this.activeChildrenJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       updatedAt = Value(updatedAt);
  static Insertable<Conversation> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<DateTime>? updatedAt,
    Expression<String>? activeChildrenJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (activeChildrenJson != null)
        'active_children_json': activeChildrenJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConversationsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<DateTime>? updatedAt,
    Value<String?>? activeChildrenJson,
    Value<int>? rowid,
  }) {
    return ConversationsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      updatedAt: updatedAt ?? this.updatedAt,
      activeChildrenJson: activeChildrenJson ?? this.activeChildrenJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (activeChildrenJson.present) {
      map['active_children_json'] = Variable<String>(activeChildrenJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('activeChildrenJson: $activeChildrenJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessagesTable extends Messages with TableInfo<$MessagesTable, Message> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _convoIdMeta = const VerificationMeta(
    'convoId',
  );
  @override
  late final GeneratedColumn<String> convoId = GeneratedColumn<String>(
    'convo_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES conversations (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _parentIdMeta = const VerificationMeta(
    'parentId',
  );
  @override
  late final GeneratedColumn<String> parentId = GeneratedColumn<String>(
    'parent_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<String> role = GeneratedColumn<String>(
    'role',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _reasoningMeta = const VerificationMeta(
    'reasoning',
  );
  @override
  late final GeneratedColumn<String> reasoning = GeneratedColumn<String>(
    'reasoning',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _modelMeta = const VerificationMeta('model');
  @override
  late final GeneratedColumn<String> model = GeneratedColumn<String>(
    'model',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _thinkingMillisMeta = const VerificationMeta(
    'thinkingMillis',
  );
  @override
  late final GeneratedColumn<int> thinkingMillis = GeneratedColumn<int>(
    'thinking_millis',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _attachmentsJsonMeta = const VerificationMeta(
    'attachmentsJson',
  );
  @override
  late final GeneratedColumn<String> attachmentsJson = GeneratedColumn<String>(
    'attachments_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _citationsJsonMeta = const VerificationMeta(
    'citationsJson',
  );
  @override
  late final GeneratedColumn<String> citationsJson = GeneratedColumn<String>(
    'citations_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _seqMeta = const VerificationMeta('seq');
  @override
  late final GeneratedColumn<int> seq = GeneratedColumn<int>(
    'seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    convoId,
    parentId,
    role,
    content,
    reasoning,
    model,
    thinkingMillis,
    attachmentsJson,
    citationsJson,
    createdAt,
    seq,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<Message> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('convo_id')) {
      context.handle(
        _convoIdMeta,
        convoId.isAcceptableOrUnknown(data['convo_id']!, _convoIdMeta),
      );
    } else if (isInserting) {
      context.missing(_convoIdMeta);
    }
    if (data.containsKey('parent_id')) {
      context.handle(
        _parentIdMeta,
        parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta),
      );
    }
    if (data.containsKey('role')) {
      context.handle(
        _roleMeta,
        role.isAcceptableOrUnknown(data['role']!, _roleMeta),
      );
    } else if (isInserting) {
      context.missing(_roleMeta);
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('reasoning')) {
      context.handle(
        _reasoningMeta,
        reasoning.isAcceptableOrUnknown(data['reasoning']!, _reasoningMeta),
      );
    }
    if (data.containsKey('model')) {
      context.handle(
        _modelMeta,
        model.isAcceptableOrUnknown(data['model']!, _modelMeta),
      );
    }
    if (data.containsKey('thinking_millis')) {
      context.handle(
        _thinkingMillisMeta,
        thinkingMillis.isAcceptableOrUnknown(
          data['thinking_millis']!,
          _thinkingMillisMeta,
        ),
      );
    }
    if (data.containsKey('attachments_json')) {
      context.handle(
        _attachmentsJsonMeta,
        attachmentsJson.isAcceptableOrUnknown(
          data['attachments_json']!,
          _attachmentsJsonMeta,
        ),
      );
    }
    if (data.containsKey('citations_json')) {
      context.handle(
        _citationsJsonMeta,
        citationsJson.isAcceptableOrUnknown(
          data['citations_json']!,
          _citationsJsonMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('seq')) {
      context.handle(
        _seqMeta,
        seq.isAcceptableOrUnknown(data['seq']!, _seqMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Message map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Message(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      convoId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}convo_id'],
      )!,
      parentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_id'],
      ),
      role: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}role'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      reasoning: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reasoning'],
      )!,
      model: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}model'],
      ),
      thinkingMillis: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}thinking_millis'],
      )!,
      attachmentsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}attachments_json'],
      ),
      citationsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}citations_json'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      seq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seq'],
      )!,
    );
  }

  @override
  $MessagesTable createAlias(String alias) {
    return $MessagesTable(attachedDatabase, alias);
  }
}

class Message extends DataClass implements Insertable<Message> {
  final String id;
  final String convoId;
  final String? parentId;
  final String role;
  final String content;
  final String reasoning;
  final String? model;
  final int thinkingMillis;
  final String? attachmentsJson;
  final String? citationsJson;
  final DateTime createdAt;
  final int seq;
  const Message({
    required this.id,
    required this.convoId,
    this.parentId,
    required this.role,
    required this.content,
    required this.reasoning,
    this.model,
    required this.thinkingMillis,
    this.attachmentsJson,
    this.citationsJson,
    required this.createdAt,
    required this.seq,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['convo_id'] = Variable<String>(convoId);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<String>(parentId);
    }
    map['role'] = Variable<String>(role);
    map['content'] = Variable<String>(content);
    map['reasoning'] = Variable<String>(reasoning);
    if (!nullToAbsent || model != null) {
      map['model'] = Variable<String>(model);
    }
    map['thinking_millis'] = Variable<int>(thinkingMillis);
    if (!nullToAbsent || attachmentsJson != null) {
      map['attachments_json'] = Variable<String>(attachmentsJson);
    }
    if (!nullToAbsent || citationsJson != null) {
      map['citations_json'] = Variable<String>(citationsJson);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    map['seq'] = Variable<int>(seq);
    return map;
  }

  MessagesCompanion toCompanion(bool nullToAbsent) {
    return MessagesCompanion(
      id: Value(id),
      convoId: Value(convoId),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      role: Value(role),
      content: Value(content),
      reasoning: Value(reasoning),
      model: model == null && nullToAbsent
          ? const Value.absent()
          : Value(model),
      thinkingMillis: Value(thinkingMillis),
      attachmentsJson: attachmentsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(attachmentsJson),
      citationsJson: citationsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(citationsJson),
      createdAt: Value(createdAt),
      seq: Value(seq),
    );
  }

  factory Message.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Message(
      id: serializer.fromJson<String>(json['id']),
      convoId: serializer.fromJson<String>(json['convoId']),
      parentId: serializer.fromJson<String?>(json['parentId']),
      role: serializer.fromJson<String>(json['role']),
      content: serializer.fromJson<String>(json['content']),
      reasoning: serializer.fromJson<String>(json['reasoning']),
      model: serializer.fromJson<String?>(json['model']),
      thinkingMillis: serializer.fromJson<int>(json['thinkingMillis']),
      attachmentsJson: serializer.fromJson<String?>(json['attachmentsJson']),
      citationsJson: serializer.fromJson<String?>(json['citationsJson']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      seq: serializer.fromJson<int>(json['seq']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'convoId': serializer.toJson<String>(convoId),
      'parentId': serializer.toJson<String?>(parentId),
      'role': serializer.toJson<String>(role),
      'content': serializer.toJson<String>(content),
      'reasoning': serializer.toJson<String>(reasoning),
      'model': serializer.toJson<String?>(model),
      'thinkingMillis': serializer.toJson<int>(thinkingMillis),
      'attachmentsJson': serializer.toJson<String?>(attachmentsJson),
      'citationsJson': serializer.toJson<String?>(citationsJson),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'seq': serializer.toJson<int>(seq),
    };
  }

  Message copyWith({
    String? id,
    String? convoId,
    Value<String?> parentId = const Value.absent(),
    String? role,
    String? content,
    String? reasoning,
    Value<String?> model = const Value.absent(),
    int? thinkingMillis,
    Value<String?> attachmentsJson = const Value.absent(),
    Value<String?> citationsJson = const Value.absent(),
    DateTime? createdAt,
    int? seq,
  }) => Message(
    id: id ?? this.id,
    convoId: convoId ?? this.convoId,
    parentId: parentId.present ? parentId.value : this.parentId,
    role: role ?? this.role,
    content: content ?? this.content,
    reasoning: reasoning ?? this.reasoning,
    model: model.present ? model.value : this.model,
    thinkingMillis: thinkingMillis ?? this.thinkingMillis,
    attachmentsJson: attachmentsJson.present
        ? attachmentsJson.value
        : this.attachmentsJson,
    citationsJson: citationsJson.present
        ? citationsJson.value
        : this.citationsJson,
    createdAt: createdAt ?? this.createdAt,
    seq: seq ?? this.seq,
  );
  Message copyWithCompanion(MessagesCompanion data) {
    return Message(
      id: data.id.present ? data.id.value : this.id,
      convoId: data.convoId.present ? data.convoId.value : this.convoId,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      role: data.role.present ? data.role.value : this.role,
      content: data.content.present ? data.content.value : this.content,
      reasoning: data.reasoning.present ? data.reasoning.value : this.reasoning,
      model: data.model.present ? data.model.value : this.model,
      thinkingMillis: data.thinkingMillis.present
          ? data.thinkingMillis.value
          : this.thinkingMillis,
      attachmentsJson: data.attachmentsJson.present
          ? data.attachmentsJson.value
          : this.attachmentsJson,
      citationsJson: data.citationsJson.present
          ? data.citationsJson.value
          : this.citationsJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      seq: data.seq.present ? data.seq.value : this.seq,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Message(')
          ..write('id: $id, ')
          ..write('convoId: $convoId, ')
          ..write('parentId: $parentId, ')
          ..write('role: $role, ')
          ..write('content: $content, ')
          ..write('reasoning: $reasoning, ')
          ..write('model: $model, ')
          ..write('thinkingMillis: $thinkingMillis, ')
          ..write('attachmentsJson: $attachmentsJson, ')
          ..write('citationsJson: $citationsJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('seq: $seq')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    convoId,
    parentId,
    role,
    content,
    reasoning,
    model,
    thinkingMillis,
    attachmentsJson,
    citationsJson,
    createdAt,
    seq,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Message &&
          other.id == this.id &&
          other.convoId == this.convoId &&
          other.parentId == this.parentId &&
          other.role == this.role &&
          other.content == this.content &&
          other.reasoning == this.reasoning &&
          other.model == this.model &&
          other.thinkingMillis == this.thinkingMillis &&
          other.attachmentsJson == this.attachmentsJson &&
          other.citationsJson == this.citationsJson &&
          other.createdAt == this.createdAt &&
          other.seq == this.seq);
}

class MessagesCompanion extends UpdateCompanion<Message> {
  final Value<String> id;
  final Value<String> convoId;
  final Value<String?> parentId;
  final Value<String> role;
  final Value<String> content;
  final Value<String> reasoning;
  final Value<String?> model;
  final Value<int> thinkingMillis;
  final Value<String?> attachmentsJson;
  final Value<String?> citationsJson;
  final Value<DateTime> createdAt;
  final Value<int> seq;
  final Value<int> rowid;
  const MessagesCompanion({
    this.id = const Value.absent(),
    this.convoId = const Value.absent(),
    this.parentId = const Value.absent(),
    this.role = const Value.absent(),
    this.content = const Value.absent(),
    this.reasoning = const Value.absent(),
    this.model = const Value.absent(),
    this.thinkingMillis = const Value.absent(),
    this.attachmentsJson = const Value.absent(),
    this.citationsJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.seq = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessagesCompanion.insert({
    required String id,
    required String convoId,
    this.parentId = const Value.absent(),
    required String role,
    required String content,
    this.reasoning = const Value.absent(),
    this.model = const Value.absent(),
    this.thinkingMillis = const Value.absent(),
    this.attachmentsJson = const Value.absent(),
    this.citationsJson = const Value.absent(),
    required DateTime createdAt,
    this.seq = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       convoId = Value(convoId),
       role = Value(role),
       content = Value(content),
       createdAt = Value(createdAt);
  static Insertable<Message> custom({
    Expression<String>? id,
    Expression<String>? convoId,
    Expression<String>? parentId,
    Expression<String>? role,
    Expression<String>? content,
    Expression<String>? reasoning,
    Expression<String>? model,
    Expression<int>? thinkingMillis,
    Expression<String>? attachmentsJson,
    Expression<String>? citationsJson,
    Expression<DateTime>? createdAt,
    Expression<int>? seq,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (convoId != null) 'convo_id': convoId,
      if (parentId != null) 'parent_id': parentId,
      if (role != null) 'role': role,
      if (content != null) 'content': content,
      if (reasoning != null) 'reasoning': reasoning,
      if (model != null) 'model': model,
      if (thinkingMillis != null) 'thinking_millis': thinkingMillis,
      if (attachmentsJson != null) 'attachments_json': attachmentsJson,
      if (citationsJson != null) 'citations_json': citationsJson,
      if (createdAt != null) 'created_at': createdAt,
      if (seq != null) 'seq': seq,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessagesCompanion copyWith({
    Value<String>? id,
    Value<String>? convoId,
    Value<String?>? parentId,
    Value<String>? role,
    Value<String>? content,
    Value<String>? reasoning,
    Value<String?>? model,
    Value<int>? thinkingMillis,
    Value<String?>? attachmentsJson,
    Value<String?>? citationsJson,
    Value<DateTime>? createdAt,
    Value<int>? seq,
    Value<int>? rowid,
  }) {
    return MessagesCompanion(
      id: id ?? this.id,
      convoId: convoId ?? this.convoId,
      parentId: parentId ?? this.parentId,
      role: role ?? this.role,
      content: content ?? this.content,
      reasoning: reasoning ?? this.reasoning,
      model: model ?? this.model,
      thinkingMillis: thinkingMillis ?? this.thinkingMillis,
      attachmentsJson: attachmentsJson ?? this.attachmentsJson,
      citationsJson: citationsJson ?? this.citationsJson,
      createdAt: createdAt ?? this.createdAt,
      seq: seq ?? this.seq,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (convoId.present) {
      map['convo_id'] = Variable<String>(convoId.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<String>(parentId.value);
    }
    if (role.present) {
      map['role'] = Variable<String>(role.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (reasoning.present) {
      map['reasoning'] = Variable<String>(reasoning.value);
    }
    if (model.present) {
      map['model'] = Variable<String>(model.value);
    }
    if (thinkingMillis.present) {
      map['thinking_millis'] = Variable<int>(thinkingMillis.value);
    }
    if (attachmentsJson.present) {
      map['attachments_json'] = Variable<String>(attachmentsJson.value);
    }
    if (citationsJson.present) {
      map['citations_json'] = Variable<String>(citationsJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (seq.present) {
      map['seq'] = Variable<int>(seq.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessagesCompanion(')
          ..write('id: $id, ')
          ..write('convoId: $convoId, ')
          ..write('parentId: $parentId, ')
          ..write('role: $role, ')
          ..write('content: $content, ')
          ..write('reasoning: $reasoning, ')
          ..write('model: $model, ')
          ..write('thinkingMillis: $thinkingMillis, ')
          ..write('attachmentsJson: $attachmentsJson, ')
          ..write('citationsJson: $citationsJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('seq: $seq, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ConversationsTable conversations = $ConversationsTable(this);
  late final $MessagesTable messages = $MessagesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [conversations, messages];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'conversations',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('messages', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$ConversationsTableCreateCompanionBuilder =
    ConversationsCompanion Function({
      required String id,
      Value<String> title,
      required DateTime updatedAt,
      Value<String?> activeChildrenJson,
      Value<int> rowid,
    });
typedef $$ConversationsTableUpdateCompanionBuilder =
    ConversationsCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<DateTime> updatedAt,
      Value<String?> activeChildrenJson,
      Value<int> rowid,
    });

final class $$ConversationsTableReferences
    extends BaseReferences<_$AppDatabase, $ConversationsTable, Conversation> {
  $$ConversationsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static MultiTypedResultKey<$MessagesTable, List<Message>> _messagesRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.messages,
    aliasName: $_aliasNameGenerator(db.conversations.id, db.messages.convoId),
  );

  $$MessagesTableProcessedTableManager get messagesRefs {
    final manager = $$MessagesTableTableManager(
      $_db,
      $_db.messages,
    ).filter((f) => f.convoId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_messagesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$ConversationsTableFilterComposer
    extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get activeChildrenJson => $composableBuilder(
    column: $table.activeChildrenJson,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> messagesRefs(
    Expression<bool> Function($$MessagesTableFilterComposer f) f,
  ) {
    final $$MessagesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.convoId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableFilterComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ConversationsTableOrderingComposer
    extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get activeChildrenJson => $composableBuilder(
    column: $table.activeChildrenJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ConversationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get activeChildrenJson => $composableBuilder(
    column: $table.activeChildrenJson,
    builder: (column) => column,
  );

  Expression<T> messagesRefs<T extends Object>(
    Expression<T> Function($$MessagesTableAnnotationComposer a) f,
  ) {
    final $$MessagesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.convoId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableAnnotationComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ConversationsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ConversationsTable,
          Conversation,
          $$ConversationsTableFilterComposer,
          $$ConversationsTableOrderingComposer,
          $$ConversationsTableAnnotationComposer,
          $$ConversationsTableCreateCompanionBuilder,
          $$ConversationsTableUpdateCompanionBuilder,
          (Conversation, $$ConversationsTableReferences),
          Conversation,
          PrefetchHooks Function({bool messagesRefs})
        > {
  $$ConversationsTableTableManager(_$AppDatabase db, $ConversationsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConversationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConversationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConversationsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String?> activeChildrenJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationsCompanion(
                id: id,
                title: title,
                updatedAt: updatedAt,
                activeChildrenJson: activeChildrenJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String> title = const Value.absent(),
                required DateTime updatedAt,
                Value<String?> activeChildrenJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationsCompanion.insert(
                id: id,
                title: title,
                updatedAt: updatedAt,
                activeChildrenJson: activeChildrenJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ConversationsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({messagesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (messagesRefs) db.messages],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (messagesRefs)
                    await $_getPrefetchedData<
                      Conversation,
                      $ConversationsTable,
                      Message
                    >(
                      currentTable: table,
                      referencedTable: $$ConversationsTableReferences
                          ._messagesRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$ConversationsTableReferences(
                            db,
                            table,
                            p0,
                          ).messagesRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.convoId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$ConversationsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ConversationsTable,
      Conversation,
      $$ConversationsTableFilterComposer,
      $$ConversationsTableOrderingComposer,
      $$ConversationsTableAnnotationComposer,
      $$ConversationsTableCreateCompanionBuilder,
      $$ConversationsTableUpdateCompanionBuilder,
      (Conversation, $$ConversationsTableReferences),
      Conversation,
      PrefetchHooks Function({bool messagesRefs})
    >;
typedef $$MessagesTableCreateCompanionBuilder =
    MessagesCompanion Function({
      required String id,
      required String convoId,
      Value<String?> parentId,
      required String role,
      required String content,
      Value<String> reasoning,
      Value<String?> model,
      Value<int> thinkingMillis,
      Value<String?> attachmentsJson,
      Value<String?> citationsJson,
      required DateTime createdAt,
      Value<int> seq,
      Value<int> rowid,
    });
typedef $$MessagesTableUpdateCompanionBuilder =
    MessagesCompanion Function({
      Value<String> id,
      Value<String> convoId,
      Value<String?> parentId,
      Value<String> role,
      Value<String> content,
      Value<String> reasoning,
      Value<String?> model,
      Value<int> thinkingMillis,
      Value<String?> attachmentsJson,
      Value<String?> citationsJson,
      Value<DateTime> createdAt,
      Value<int> seq,
      Value<int> rowid,
    });

final class $$MessagesTableReferences
    extends BaseReferences<_$AppDatabase, $MessagesTable, Message> {
  $$MessagesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ConversationsTable _convoIdTable(_$AppDatabase db) =>
      db.conversations.createAlias(
        $_aliasNameGenerator(db.messages.convoId, db.conversations.id),
      );

  $$ConversationsTableProcessedTableManager get convoId {
    final $_column = $_itemColumn<String>('convo_id')!;

    final manager = $$ConversationsTableTableManager(
      $_db,
      $_db.conversations,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_convoIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$MessagesTableFilterComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reasoning => $composableBuilder(
    column: $table.reasoning,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get model => $composableBuilder(
    column: $table.model,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get thinkingMillis => $composableBuilder(
    column: $table.thinkingMillis,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get attachmentsJson => $composableBuilder(
    column: $table.attachmentsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get citationsJson => $composableBuilder(
    column: $table.citationsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnFilters(column),
  );

  $$ConversationsTableFilterComposer get convoId {
    final $$ConversationsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.convoId,
      referencedTable: $db.conversations,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConversationsTableFilterComposer(
            $db: $db,
            $table: $db.conversations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessagesTableOrderingComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reasoning => $composableBuilder(
    column: $table.reasoning,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get model => $composableBuilder(
    column: $table.model,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get thinkingMillis => $composableBuilder(
    column: $table.thinkingMillis,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get attachmentsJson => $composableBuilder(
    column: $table.attachmentsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get citationsJson => $composableBuilder(
    column: $table.citationsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnOrderings(column),
  );

  $$ConversationsTableOrderingComposer get convoId {
    final $$ConversationsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.convoId,
      referencedTable: $db.conversations,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConversationsTableOrderingComposer(
            $db: $db,
            $table: $db.conversations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessagesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get parentId =>
      $composableBuilder(column: $table.parentId, builder: (column) => column);

  GeneratedColumn<String> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<String> get reasoning =>
      $composableBuilder(column: $table.reasoning, builder: (column) => column);

  GeneratedColumn<String> get model =>
      $composableBuilder(column: $table.model, builder: (column) => column);

  GeneratedColumn<int> get thinkingMillis => $composableBuilder(
    column: $table.thinkingMillis,
    builder: (column) => column,
  );

  GeneratedColumn<String> get attachmentsJson => $composableBuilder(
    column: $table.attachmentsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get citationsJson => $composableBuilder(
    column: $table.citationsJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get seq =>
      $composableBuilder(column: $table.seq, builder: (column) => column);

  $$ConversationsTableAnnotationComposer get convoId {
    final $$ConversationsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.convoId,
      referencedTable: $db.conversations,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConversationsTableAnnotationComposer(
            $db: $db,
            $table: $db.conversations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessagesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MessagesTable,
          Message,
          $$MessagesTableFilterComposer,
          $$MessagesTableOrderingComposer,
          $$MessagesTableAnnotationComposer,
          $$MessagesTableCreateCompanionBuilder,
          $$MessagesTableUpdateCompanionBuilder,
          (Message, $$MessagesTableReferences),
          Message,
          PrefetchHooks Function({bool convoId})
        > {
  $$MessagesTableTableManager(_$AppDatabase db, $MessagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> convoId = const Value.absent(),
                Value<String?> parentId = const Value.absent(),
                Value<String> role = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<String> reasoning = const Value.absent(),
                Value<String?> model = const Value.absent(),
                Value<int> thinkingMillis = const Value.absent(),
                Value<String?> attachmentsJson = const Value.absent(),
                Value<String?> citationsJson = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> seq = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessagesCompanion(
                id: id,
                convoId: convoId,
                parentId: parentId,
                role: role,
                content: content,
                reasoning: reasoning,
                model: model,
                thinkingMillis: thinkingMillis,
                attachmentsJson: attachmentsJson,
                citationsJson: citationsJson,
                createdAt: createdAt,
                seq: seq,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String convoId,
                Value<String?> parentId = const Value.absent(),
                required String role,
                required String content,
                Value<String> reasoning = const Value.absent(),
                Value<String?> model = const Value.absent(),
                Value<int> thinkingMillis = const Value.absent(),
                Value<String?> attachmentsJson = const Value.absent(),
                Value<String?> citationsJson = const Value.absent(),
                required DateTime createdAt,
                Value<int> seq = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessagesCompanion.insert(
                id: id,
                convoId: convoId,
                parentId: parentId,
                role: role,
                content: content,
                reasoning: reasoning,
                model: model,
                thinkingMillis: thinkingMillis,
                attachmentsJson: attachmentsJson,
                citationsJson: citationsJson,
                createdAt: createdAt,
                seq: seq,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$MessagesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({convoId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (convoId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.convoId,
                                referencedTable: $$MessagesTableReferences
                                    ._convoIdTable(db),
                                referencedColumn: $$MessagesTableReferences
                                    ._convoIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$MessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MessagesTable,
      Message,
      $$MessagesTableFilterComposer,
      $$MessagesTableOrderingComposer,
      $$MessagesTableAnnotationComposer,
      $$MessagesTableCreateCompanionBuilder,
      $$MessagesTableUpdateCompanionBuilder,
      (Message, $$MessagesTableReferences),
      Message,
      PrefetchHooks Function({bool convoId})
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ConversationsTableTableManager get conversations =>
      $$ConversationsTableTableManager(_db, _db.conversations);
  $$MessagesTableTableManager get messages =>
      $$MessagesTableTableManager(_db, _db.messages);
}
