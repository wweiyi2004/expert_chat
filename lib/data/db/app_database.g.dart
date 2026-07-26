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
  static const VerificationMeta _modeMeta = const VerificationMeta('mode');
  @override
  late final GeneratedColumn<String> mode = GeneratedColumn<String>(
    'mode',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('chat'),
  );
  static const VerificationMeta _characterIdMeta = const VerificationMeta(
    'characterId',
  );
  @override
  late final GeneratedColumn<String> characterId = GeneratedColumn<String>(
    'character_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _worldInfoIdsJsonMeta = const VerificationMeta(
    'worldInfoIdsJson',
  );
  @override
  late final GeneratedColumn<String> worldInfoIdsJson = GeneratedColumn<String>(
    'world_info_ids_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _outlineMeta = const VerificationMeta(
    'outline',
  );
  @override
  late final GeneratedColumn<String> outline = GeneratedColumn<String>(
    'outline',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _authorNoteMeta = const VerificationMeta(
    'authorNote',
  );
  @override
  late final GeneratedColumn<String> authorNote = GeneratedColumn<String>(
    'author_note',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _plotCursorMeta = const VerificationMeta(
    'plotCursor',
  );
  @override
  late final GeneratedColumn<int> plotCursor = GeneratedColumn<int>(
    'plot_cursor',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _participantIdsJsonMeta =
      const VerificationMeta('participantIdsJson');
  @override
  late final GeneratedColumn<String> participantIdsJson =
      GeneratedColumn<String>(
        'participant_ids_json',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _venueMeta = const VerificationMeta('venue');
  @override
  late final GeneratedColumn<String> venue = GeneratedColumn<String>(
    'venue',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _nextSpeakerIndexMeta = const VerificationMeta(
    'nextSpeakerIndex',
  );
  @override
  late final GeneratedColumn<int> nextSpeakerIndex = GeneratedColumn<int>(
    'next_speaker_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _localCastJsonMeta = const VerificationMeta(
    'localCastJson',
  );
  @override
  late final GeneratedColumn<String> localCastJson = GeneratedColumn<String>(
    'local_cast_json',
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
    mode,
    characterId,
    worldInfoIdsJson,
    outline,
    authorNote,
    plotCursor,
    participantIdsJson,
    venue,
    nextSpeakerIndex,
    localCastJson,
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
    if (data.containsKey('mode')) {
      context.handle(
        _modeMeta,
        mode.isAcceptableOrUnknown(data['mode']!, _modeMeta),
      );
    }
    if (data.containsKey('character_id')) {
      context.handle(
        _characterIdMeta,
        characterId.isAcceptableOrUnknown(
          data['character_id']!,
          _characterIdMeta,
        ),
      );
    }
    if (data.containsKey('world_info_ids_json')) {
      context.handle(
        _worldInfoIdsJsonMeta,
        worldInfoIdsJson.isAcceptableOrUnknown(
          data['world_info_ids_json']!,
          _worldInfoIdsJsonMeta,
        ),
      );
    }
    if (data.containsKey('outline')) {
      context.handle(
        _outlineMeta,
        outline.isAcceptableOrUnknown(data['outline']!, _outlineMeta),
      );
    }
    if (data.containsKey('author_note')) {
      context.handle(
        _authorNoteMeta,
        authorNote.isAcceptableOrUnknown(data['author_note']!, _authorNoteMeta),
      );
    }
    if (data.containsKey('plot_cursor')) {
      context.handle(
        _plotCursorMeta,
        plotCursor.isAcceptableOrUnknown(data['plot_cursor']!, _plotCursorMeta),
      );
    }
    if (data.containsKey('participant_ids_json')) {
      context.handle(
        _participantIdsJsonMeta,
        participantIdsJson.isAcceptableOrUnknown(
          data['participant_ids_json']!,
          _participantIdsJsonMeta,
        ),
      );
    }
    if (data.containsKey('venue')) {
      context.handle(
        _venueMeta,
        venue.isAcceptableOrUnknown(data['venue']!, _venueMeta),
      );
    }
    if (data.containsKey('next_speaker_index')) {
      context.handle(
        _nextSpeakerIndexMeta,
        nextSpeakerIndex.isAcceptableOrUnknown(
          data['next_speaker_index']!,
          _nextSpeakerIndexMeta,
        ),
      );
    }
    if (data.containsKey('local_cast_json')) {
      context.handle(
        _localCastJsonMeta,
        localCastJson.isAcceptableOrUnknown(
          data['local_cast_json']!,
          _localCastJsonMeta,
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
      mode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mode'],
      )!,
      characterId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}character_id'],
      ),
      worldInfoIdsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}world_info_ids_json'],
      ),
      outline: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}outline'],
      )!,
      authorNote: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}author_note'],
      )!,
      plotCursor: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}plot_cursor'],
      )!,
      participantIdsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}participant_ids_json'],
      ),
      venue: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}venue'],
      )!,
      nextSpeakerIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}next_speaker_index'],
      )!,
      localCastJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_cast_json'],
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
  final String mode;
  final String? characterId;
  final String? worldInfoIdsJson;
  final String outline;
  final String authorNote;
  final int plotCursor;
  final String? participantIdsJson;
  final String venue;
  final int nextSpeakerIndex;
  final String? localCastJson;
  const Conversation({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.activeChildrenJson,
    required this.mode,
    this.characterId,
    this.worldInfoIdsJson,
    required this.outline,
    required this.authorNote,
    required this.plotCursor,
    this.participantIdsJson,
    required this.venue,
    required this.nextSpeakerIndex,
    this.localCastJson,
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
    map['mode'] = Variable<String>(mode);
    if (!nullToAbsent || characterId != null) {
      map['character_id'] = Variable<String>(characterId);
    }
    if (!nullToAbsent || worldInfoIdsJson != null) {
      map['world_info_ids_json'] = Variable<String>(worldInfoIdsJson);
    }
    map['outline'] = Variable<String>(outline);
    map['author_note'] = Variable<String>(authorNote);
    map['plot_cursor'] = Variable<int>(plotCursor);
    if (!nullToAbsent || participantIdsJson != null) {
      map['participant_ids_json'] = Variable<String>(participantIdsJson);
    }
    map['venue'] = Variable<String>(venue);
    map['next_speaker_index'] = Variable<int>(nextSpeakerIndex);
    if (!nullToAbsent || localCastJson != null) {
      map['local_cast_json'] = Variable<String>(localCastJson);
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
      mode: Value(mode),
      characterId: characterId == null && nullToAbsent
          ? const Value.absent()
          : Value(characterId),
      worldInfoIdsJson: worldInfoIdsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(worldInfoIdsJson),
      outline: Value(outline),
      authorNote: Value(authorNote),
      plotCursor: Value(plotCursor),
      participantIdsJson: participantIdsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(participantIdsJson),
      venue: Value(venue),
      nextSpeakerIndex: Value(nextSpeakerIndex),
      localCastJson: localCastJson == null && nullToAbsent
          ? const Value.absent()
          : Value(localCastJson),
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
      mode: serializer.fromJson<String>(json['mode']),
      characterId: serializer.fromJson<String?>(json['characterId']),
      worldInfoIdsJson: serializer.fromJson<String?>(json['worldInfoIdsJson']),
      outline: serializer.fromJson<String>(json['outline']),
      authorNote: serializer.fromJson<String>(json['authorNote']),
      plotCursor: serializer.fromJson<int>(json['plotCursor']),
      participantIdsJson: serializer.fromJson<String?>(
        json['participantIdsJson'],
      ),
      venue: serializer.fromJson<String>(json['venue']),
      nextSpeakerIndex: serializer.fromJson<int>(json['nextSpeakerIndex']),
      localCastJson: serializer.fromJson<String?>(json['localCastJson']),
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
      'mode': serializer.toJson<String>(mode),
      'characterId': serializer.toJson<String?>(characterId),
      'worldInfoIdsJson': serializer.toJson<String?>(worldInfoIdsJson),
      'outline': serializer.toJson<String>(outline),
      'authorNote': serializer.toJson<String>(authorNote),
      'plotCursor': serializer.toJson<int>(plotCursor),
      'participantIdsJson': serializer.toJson<String?>(participantIdsJson),
      'venue': serializer.toJson<String>(venue),
      'nextSpeakerIndex': serializer.toJson<int>(nextSpeakerIndex),
      'localCastJson': serializer.toJson<String?>(localCastJson),
    };
  }

  Conversation copyWith({
    String? id,
    String? title,
    DateTime? updatedAt,
    Value<String?> activeChildrenJson = const Value.absent(),
    String? mode,
    Value<String?> characterId = const Value.absent(),
    Value<String?> worldInfoIdsJson = const Value.absent(),
    String? outline,
    String? authorNote,
    int? plotCursor,
    Value<String?> participantIdsJson = const Value.absent(),
    String? venue,
    int? nextSpeakerIndex,
    Value<String?> localCastJson = const Value.absent(),
  }) => Conversation(
    id: id ?? this.id,
    title: title ?? this.title,
    updatedAt: updatedAt ?? this.updatedAt,
    activeChildrenJson: activeChildrenJson.present
        ? activeChildrenJson.value
        : this.activeChildrenJson,
    mode: mode ?? this.mode,
    characterId: characterId.present ? characterId.value : this.characterId,
    worldInfoIdsJson: worldInfoIdsJson.present
        ? worldInfoIdsJson.value
        : this.worldInfoIdsJson,
    outline: outline ?? this.outline,
    authorNote: authorNote ?? this.authorNote,
    plotCursor: plotCursor ?? this.plotCursor,
    participantIdsJson: participantIdsJson.present
        ? participantIdsJson.value
        : this.participantIdsJson,
    venue: venue ?? this.venue,
    nextSpeakerIndex: nextSpeakerIndex ?? this.nextSpeakerIndex,
    localCastJson: localCastJson.present
        ? localCastJson.value
        : this.localCastJson,
  );
  Conversation copyWithCompanion(ConversationsCompanion data) {
    return Conversation(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      activeChildrenJson: data.activeChildrenJson.present
          ? data.activeChildrenJson.value
          : this.activeChildrenJson,
      mode: data.mode.present ? data.mode.value : this.mode,
      characterId: data.characterId.present
          ? data.characterId.value
          : this.characterId,
      worldInfoIdsJson: data.worldInfoIdsJson.present
          ? data.worldInfoIdsJson.value
          : this.worldInfoIdsJson,
      outline: data.outline.present ? data.outline.value : this.outline,
      authorNote: data.authorNote.present
          ? data.authorNote.value
          : this.authorNote,
      plotCursor: data.plotCursor.present
          ? data.plotCursor.value
          : this.plotCursor,
      participantIdsJson: data.participantIdsJson.present
          ? data.participantIdsJson.value
          : this.participantIdsJson,
      venue: data.venue.present ? data.venue.value : this.venue,
      nextSpeakerIndex: data.nextSpeakerIndex.present
          ? data.nextSpeakerIndex.value
          : this.nextSpeakerIndex,
      localCastJson: data.localCastJson.present
          ? data.localCastJson.value
          : this.localCastJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Conversation(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('activeChildrenJson: $activeChildrenJson, ')
          ..write('mode: $mode, ')
          ..write('characterId: $characterId, ')
          ..write('worldInfoIdsJson: $worldInfoIdsJson, ')
          ..write('outline: $outline, ')
          ..write('authorNote: $authorNote, ')
          ..write('plotCursor: $plotCursor, ')
          ..write('participantIdsJson: $participantIdsJson, ')
          ..write('venue: $venue, ')
          ..write('nextSpeakerIndex: $nextSpeakerIndex, ')
          ..write('localCastJson: $localCastJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    updatedAt,
    activeChildrenJson,
    mode,
    characterId,
    worldInfoIdsJson,
    outline,
    authorNote,
    plotCursor,
    participantIdsJson,
    venue,
    nextSpeakerIndex,
    localCastJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Conversation &&
          other.id == this.id &&
          other.title == this.title &&
          other.updatedAt == this.updatedAt &&
          other.activeChildrenJson == this.activeChildrenJson &&
          other.mode == this.mode &&
          other.characterId == this.characterId &&
          other.worldInfoIdsJson == this.worldInfoIdsJson &&
          other.outline == this.outline &&
          other.authorNote == this.authorNote &&
          other.plotCursor == this.plotCursor &&
          other.participantIdsJson == this.participantIdsJson &&
          other.venue == this.venue &&
          other.nextSpeakerIndex == this.nextSpeakerIndex &&
          other.localCastJson == this.localCastJson);
}

class ConversationsCompanion extends UpdateCompanion<Conversation> {
  final Value<String> id;
  final Value<String> title;
  final Value<DateTime> updatedAt;
  final Value<String?> activeChildrenJson;
  final Value<String> mode;
  final Value<String?> characterId;
  final Value<String?> worldInfoIdsJson;
  final Value<String> outline;
  final Value<String> authorNote;
  final Value<int> plotCursor;
  final Value<String?> participantIdsJson;
  final Value<String> venue;
  final Value<int> nextSpeakerIndex;
  final Value<String?> localCastJson;
  final Value<int> rowid;
  const ConversationsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.activeChildrenJson = const Value.absent(),
    this.mode = const Value.absent(),
    this.characterId = const Value.absent(),
    this.worldInfoIdsJson = const Value.absent(),
    this.outline = const Value.absent(),
    this.authorNote = const Value.absent(),
    this.plotCursor = const Value.absent(),
    this.participantIdsJson = const Value.absent(),
    this.venue = const Value.absent(),
    this.nextSpeakerIndex = const Value.absent(),
    this.localCastJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConversationsCompanion.insert({
    required String id,
    this.title = const Value.absent(),
    required DateTime updatedAt,
    this.activeChildrenJson = const Value.absent(),
    this.mode = const Value.absent(),
    this.characterId = const Value.absent(),
    this.worldInfoIdsJson = const Value.absent(),
    this.outline = const Value.absent(),
    this.authorNote = const Value.absent(),
    this.plotCursor = const Value.absent(),
    this.participantIdsJson = const Value.absent(),
    this.venue = const Value.absent(),
    this.nextSpeakerIndex = const Value.absent(),
    this.localCastJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       updatedAt = Value(updatedAt);
  static Insertable<Conversation> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<DateTime>? updatedAt,
    Expression<String>? activeChildrenJson,
    Expression<String>? mode,
    Expression<String>? characterId,
    Expression<String>? worldInfoIdsJson,
    Expression<String>? outline,
    Expression<String>? authorNote,
    Expression<int>? plotCursor,
    Expression<String>? participantIdsJson,
    Expression<String>? venue,
    Expression<int>? nextSpeakerIndex,
    Expression<String>? localCastJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (activeChildrenJson != null)
        'active_children_json': activeChildrenJson,
      if (mode != null) 'mode': mode,
      if (characterId != null) 'character_id': characterId,
      if (worldInfoIdsJson != null) 'world_info_ids_json': worldInfoIdsJson,
      if (outline != null) 'outline': outline,
      if (authorNote != null) 'author_note': authorNote,
      if (plotCursor != null) 'plot_cursor': plotCursor,
      if (participantIdsJson != null)
        'participant_ids_json': participantIdsJson,
      if (venue != null) 'venue': venue,
      if (nextSpeakerIndex != null) 'next_speaker_index': nextSpeakerIndex,
      if (localCastJson != null) 'local_cast_json': localCastJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConversationsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<DateTime>? updatedAt,
    Value<String?>? activeChildrenJson,
    Value<String>? mode,
    Value<String?>? characterId,
    Value<String?>? worldInfoIdsJson,
    Value<String>? outline,
    Value<String>? authorNote,
    Value<int>? plotCursor,
    Value<String?>? participantIdsJson,
    Value<String>? venue,
    Value<int>? nextSpeakerIndex,
    Value<String?>? localCastJson,
    Value<int>? rowid,
  }) {
    return ConversationsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      updatedAt: updatedAt ?? this.updatedAt,
      activeChildrenJson: activeChildrenJson ?? this.activeChildrenJson,
      mode: mode ?? this.mode,
      characterId: characterId ?? this.characterId,
      worldInfoIdsJson: worldInfoIdsJson ?? this.worldInfoIdsJson,
      outline: outline ?? this.outline,
      authorNote: authorNote ?? this.authorNote,
      plotCursor: plotCursor ?? this.plotCursor,
      participantIdsJson: participantIdsJson ?? this.participantIdsJson,
      venue: venue ?? this.venue,
      nextSpeakerIndex: nextSpeakerIndex ?? this.nextSpeakerIndex,
      localCastJson: localCastJson ?? this.localCastJson,
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
    if (mode.present) {
      map['mode'] = Variable<String>(mode.value);
    }
    if (characterId.present) {
      map['character_id'] = Variable<String>(characterId.value);
    }
    if (worldInfoIdsJson.present) {
      map['world_info_ids_json'] = Variable<String>(worldInfoIdsJson.value);
    }
    if (outline.present) {
      map['outline'] = Variable<String>(outline.value);
    }
    if (authorNote.present) {
      map['author_note'] = Variable<String>(authorNote.value);
    }
    if (plotCursor.present) {
      map['plot_cursor'] = Variable<int>(plotCursor.value);
    }
    if (participantIdsJson.present) {
      map['participant_ids_json'] = Variable<String>(participantIdsJson.value);
    }
    if (venue.present) {
      map['venue'] = Variable<String>(venue.value);
    }
    if (nextSpeakerIndex.present) {
      map['next_speaker_index'] = Variable<int>(nextSpeakerIndex.value);
    }
    if (localCastJson.present) {
      map['local_cast_json'] = Variable<String>(localCastJson.value);
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
          ..write('mode: $mode, ')
          ..write('characterId: $characterId, ')
          ..write('worldInfoIdsJson: $worldInfoIdsJson, ')
          ..write('outline: $outline, ')
          ..write('authorNote: $authorNote, ')
          ..write('plotCursor: $plotCursor, ')
          ..write('participantIdsJson: $participantIdsJson, ')
          ..write('venue: $venue, ')
          ..write('nextSpeakerIndex: $nextSpeakerIndex, ')
          ..write('localCastJson: $localCastJson, ')
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
  static const VerificationMeta _speakerIdMeta = const VerificationMeta(
    'speakerId',
  );
  @override
  late final GeneratedColumn<String> speakerId = GeneratedColumn<String>(
    'speaker_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _speakerNameMeta = const VerificationMeta(
    'speakerName',
  );
  @override
  late final GeneratedColumn<String> speakerName = GeneratedColumn<String>(
    'speaker_name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('text'),
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
    speakerId,
    speakerName,
    kind,
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
    if (data.containsKey('speaker_id')) {
      context.handle(
        _speakerIdMeta,
        speakerId.isAcceptableOrUnknown(data['speaker_id']!, _speakerIdMeta),
      );
    }
    if (data.containsKey('speaker_name')) {
      context.handle(
        _speakerNameMeta,
        speakerName.isAcceptableOrUnknown(
          data['speaker_name']!,
          _speakerNameMeta,
        ),
      );
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
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
      speakerId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}speaker_id'],
      ),
      speakerName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}speaker_name'],
      ),
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
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
  final String? speakerId;
  final String? speakerName;
  final String kind;
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
    this.speakerId,
    this.speakerName,
    required this.kind,
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
    if (!nullToAbsent || speakerId != null) {
      map['speaker_id'] = Variable<String>(speakerId);
    }
    if (!nullToAbsent || speakerName != null) {
      map['speaker_name'] = Variable<String>(speakerName);
    }
    map['kind'] = Variable<String>(kind);
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
      speakerId: speakerId == null && nullToAbsent
          ? const Value.absent()
          : Value(speakerId),
      speakerName: speakerName == null && nullToAbsent
          ? const Value.absent()
          : Value(speakerName),
      kind: Value(kind),
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
      speakerId: serializer.fromJson<String?>(json['speakerId']),
      speakerName: serializer.fromJson<String?>(json['speakerName']),
      kind: serializer.fromJson<String>(json['kind']),
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
      'speakerId': serializer.toJson<String?>(speakerId),
      'speakerName': serializer.toJson<String?>(speakerName),
      'kind': serializer.toJson<String>(kind),
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
    Value<String?> speakerId = const Value.absent(),
    Value<String?> speakerName = const Value.absent(),
    String? kind,
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
    speakerId: speakerId.present ? speakerId.value : this.speakerId,
    speakerName: speakerName.present ? speakerName.value : this.speakerName,
    kind: kind ?? this.kind,
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
      speakerId: data.speakerId.present ? data.speakerId.value : this.speakerId,
      speakerName: data.speakerName.present
          ? data.speakerName.value
          : this.speakerName,
      kind: data.kind.present ? data.kind.value : this.kind,
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
          ..write('seq: $seq, ')
          ..write('speakerId: $speakerId, ')
          ..write('speakerName: $speakerName, ')
          ..write('kind: $kind')
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
    speakerId,
    speakerName,
    kind,
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
          other.seq == this.seq &&
          other.speakerId == this.speakerId &&
          other.speakerName == this.speakerName &&
          other.kind == this.kind);
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
  final Value<String?> speakerId;
  final Value<String?> speakerName;
  final Value<String> kind;
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
    this.speakerId = const Value.absent(),
    this.speakerName = const Value.absent(),
    this.kind = const Value.absent(),
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
    this.speakerId = const Value.absent(),
    this.speakerName = const Value.absent(),
    this.kind = const Value.absent(),
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
    Expression<String>? speakerId,
    Expression<String>? speakerName,
    Expression<String>? kind,
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
      if (speakerId != null) 'speaker_id': speakerId,
      if (speakerName != null) 'speaker_name': speakerName,
      if (kind != null) 'kind': kind,
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
    Value<String?>? speakerId,
    Value<String?>? speakerName,
    Value<String>? kind,
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
      speakerId: speakerId ?? this.speakerId,
      speakerName: speakerName ?? this.speakerName,
      kind: kind ?? this.kind,
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
    if (speakerId.present) {
      map['speaker_id'] = Variable<String>(speakerId.value);
    }
    if (speakerName.present) {
      map['speaker_name'] = Variable<String>(speakerName.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
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
          ..write('speakerId: $speakerId, ')
          ..write('speakerName: $speakerName, ')
          ..write('kind: $kind, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CharacterCardsTable extends CharacterCards
    with TableInfo<$CharacterCardsTable, CharacterCardRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CharacterCardsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _personalityMeta = const VerificationMeta(
    'personality',
  );
  @override
  late final GeneratedColumn<String> personality = GeneratedColumn<String>(
    'personality',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _scenarioMeta = const VerificationMeta(
    'scenario',
  );
  @override
  late final GeneratedColumn<String> scenario = GeneratedColumn<String>(
    'scenario',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _firstMesMeta = const VerificationMeta(
    'firstMes',
  );
  @override
  late final GeneratedColumn<String> firstMes = GeneratedColumn<String>(
    'first_mes',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _exampleDialogsMeta = const VerificationMeta(
    'exampleDialogs',
  );
  @override
  late final GeneratedColumn<String> exampleDialogs = GeneratedColumn<String>(
    'example_dialogs',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _systemPromptMeta = const VerificationMeta(
    'systemPrompt',
  );
  @override
  late final GeneratedColumn<String> systemPrompt = GeneratedColumn<String>(
    'system_prompt',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
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
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    description,
    personality,
    scenario,
    firstMes,
    exampleDialogs,
    systemPrompt,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'character_cards';
  @override
  VerificationContext validateIntegrity(
    Insertable<CharacterCardRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    }
    if (data.containsKey('personality')) {
      context.handle(
        _personalityMeta,
        personality.isAcceptableOrUnknown(
          data['personality']!,
          _personalityMeta,
        ),
      );
    }
    if (data.containsKey('scenario')) {
      context.handle(
        _scenarioMeta,
        scenario.isAcceptableOrUnknown(data['scenario']!, _scenarioMeta),
      );
    }
    if (data.containsKey('first_mes')) {
      context.handle(
        _firstMesMeta,
        firstMes.isAcceptableOrUnknown(data['first_mes']!, _firstMesMeta),
      );
    }
    if (data.containsKey('example_dialogs')) {
      context.handle(
        _exampleDialogsMeta,
        exampleDialogs.isAcceptableOrUnknown(
          data['example_dialogs']!,
          _exampleDialogsMeta,
        ),
      );
    }
    if (data.containsKey('system_prompt')) {
      context.handle(
        _systemPromptMeta,
        systemPrompt.isAcceptableOrUnknown(
          data['system_prompt']!,
          _systemPromptMeta,
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
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CharacterCardRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CharacterCardRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      )!,
      personality: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}personality'],
      )!,
      scenario: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scenario'],
      )!,
      firstMes: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}first_mes'],
      )!,
      exampleDialogs: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}example_dialogs'],
      )!,
      systemPrompt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}system_prompt'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $CharacterCardsTable createAlias(String alias) {
    return $CharacterCardsTable(attachedDatabase, alias);
  }
}

class CharacterCardRow extends DataClass
    implements Insertable<CharacterCardRow> {
  final String id;
  final String name;
  final String description;
  final String personality;
  final String scenario;
  final String firstMes;
  final String exampleDialogs;
  final String systemPrompt;
  final DateTime createdAt;
  final DateTime updatedAt;
  const CharacterCardRow({
    required this.id,
    required this.name,
    required this.description,
    required this.personality,
    required this.scenario,
    required this.firstMes,
    required this.exampleDialogs,
    required this.systemPrompt,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['description'] = Variable<String>(description);
    map['personality'] = Variable<String>(personality);
    map['scenario'] = Variable<String>(scenario);
    map['first_mes'] = Variable<String>(firstMes);
    map['example_dialogs'] = Variable<String>(exampleDialogs);
    map['system_prompt'] = Variable<String>(systemPrompt);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  CharacterCardsCompanion toCompanion(bool nullToAbsent) {
    return CharacterCardsCompanion(
      id: Value(id),
      name: Value(name),
      description: Value(description),
      personality: Value(personality),
      scenario: Value(scenario),
      firstMes: Value(firstMes),
      exampleDialogs: Value(exampleDialogs),
      systemPrompt: Value(systemPrompt),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory CharacterCardRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CharacterCardRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      description: serializer.fromJson<String>(json['description']),
      personality: serializer.fromJson<String>(json['personality']),
      scenario: serializer.fromJson<String>(json['scenario']),
      firstMes: serializer.fromJson<String>(json['firstMes']),
      exampleDialogs: serializer.fromJson<String>(json['exampleDialogs']),
      systemPrompt: serializer.fromJson<String>(json['systemPrompt']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'description': serializer.toJson<String>(description),
      'personality': serializer.toJson<String>(personality),
      'scenario': serializer.toJson<String>(scenario),
      'firstMes': serializer.toJson<String>(firstMes),
      'exampleDialogs': serializer.toJson<String>(exampleDialogs),
      'systemPrompt': serializer.toJson<String>(systemPrompt),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  CharacterCardRow copyWith({
    String? id,
    String? name,
    String? description,
    String? personality,
    String? scenario,
    String? firstMes,
    String? exampleDialogs,
    String? systemPrompt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => CharacterCardRow(
    id: id ?? this.id,
    name: name ?? this.name,
    description: description ?? this.description,
    personality: personality ?? this.personality,
    scenario: scenario ?? this.scenario,
    firstMes: firstMes ?? this.firstMes,
    exampleDialogs: exampleDialogs ?? this.exampleDialogs,
    systemPrompt: systemPrompt ?? this.systemPrompt,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  CharacterCardRow copyWithCompanion(CharacterCardsCompanion data) {
    return CharacterCardRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      description: data.description.present
          ? data.description.value
          : this.description,
      personality: data.personality.present
          ? data.personality.value
          : this.personality,
      scenario: data.scenario.present ? data.scenario.value : this.scenario,
      firstMes: data.firstMes.present ? data.firstMes.value : this.firstMes,
      exampleDialogs: data.exampleDialogs.present
          ? data.exampleDialogs.value
          : this.exampleDialogs,
      systemPrompt: data.systemPrompt.present
          ? data.systemPrompt.value
          : this.systemPrompt,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CharacterCardRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('description: $description, ')
          ..write('personality: $personality, ')
          ..write('scenario: $scenario, ')
          ..write('firstMes: $firstMes, ')
          ..write('exampleDialogs: $exampleDialogs, ')
          ..write('systemPrompt: $systemPrompt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    description,
    personality,
    scenario,
    firstMes,
    exampleDialogs,
    systemPrompt,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CharacterCardRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.description == this.description &&
          other.personality == this.personality &&
          other.scenario == this.scenario &&
          other.firstMes == this.firstMes &&
          other.exampleDialogs == this.exampleDialogs &&
          other.systemPrompt == this.systemPrompt &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class CharacterCardsCompanion extends UpdateCompanion<CharacterCardRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> description;
  final Value<String> personality;
  final Value<String> scenario;
  final Value<String> firstMes;
  final Value<String> exampleDialogs;
  final Value<String> systemPrompt;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const CharacterCardsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.description = const Value.absent(),
    this.personality = const Value.absent(),
    this.scenario = const Value.absent(),
    this.firstMes = const Value.absent(),
    this.exampleDialogs = const Value.absent(),
    this.systemPrompt = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CharacterCardsCompanion.insert({
    required String id,
    required String name,
    this.description = const Value.absent(),
    this.personality = const Value.absent(),
    this.scenario = const Value.absent(),
    this.firstMes = const Value.absent(),
    this.exampleDialogs = const Value.absent(),
    this.systemPrompt = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<CharacterCardRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? description,
    Expression<String>? personality,
    Expression<String>? scenario,
    Expression<String>? firstMes,
    Expression<String>? exampleDialogs,
    Expression<String>? systemPrompt,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (description != null) 'description': description,
      if (personality != null) 'personality': personality,
      if (scenario != null) 'scenario': scenario,
      if (firstMes != null) 'first_mes': firstMes,
      if (exampleDialogs != null) 'example_dialogs': exampleDialogs,
      if (systemPrompt != null) 'system_prompt': systemPrompt,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CharacterCardsCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? description,
    Value<String>? personality,
    Value<String>? scenario,
    Value<String>? firstMes,
    Value<String>? exampleDialogs,
    Value<String>? systemPrompt,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return CharacterCardsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      personality: personality ?? this.personality,
      scenario: scenario ?? this.scenario,
      firstMes: firstMes ?? this.firstMes,
      exampleDialogs: exampleDialogs ?? this.exampleDialogs,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (personality.present) {
      map['personality'] = Variable<String>(personality.value);
    }
    if (scenario.present) {
      map['scenario'] = Variable<String>(scenario.value);
    }
    if (firstMes.present) {
      map['first_mes'] = Variable<String>(firstMes.value);
    }
    if (exampleDialogs.present) {
      map['example_dialogs'] = Variable<String>(exampleDialogs.value);
    }
    if (systemPrompt.present) {
      map['system_prompt'] = Variable<String>(systemPrompt.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CharacterCardsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('description: $description, ')
          ..write('personality: $personality, ')
          ..write('scenario: $scenario, ')
          ..write('firstMes: $firstMes, ')
          ..write('exampleDialogs: $exampleDialogs, ')
          ..write('systemPrompt: $systemPrompt, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $WorldInfoEntriesTable extends WorldInfoEntries
    with TableInfo<$WorldInfoEntriesTable, WorldInfoEntryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $WorldInfoEntriesTable(this.attachedDatabase, [this._alias]);
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
    requiredDuringInsert: true,
  );
  static const VerificationMeta _keysJsonMeta = const VerificationMeta(
    'keysJson',
  );
  @override
  late final GeneratedColumn<String> keysJson = GeneratedColumn<String>(
    'keys_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
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
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _alwaysOnMeta = const VerificationMeta(
    'alwaysOn',
  );
  @override
  late final GeneratedColumn<bool> alwaysOn = GeneratedColumn<bool>(
    'always_on',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("always_on" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _enabledMeta = const VerificationMeta(
    'enabled',
  );
  @override
  late final GeneratedColumn<bool> enabled = GeneratedColumn<bool>(
    'enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _priorityMeta = const VerificationMeta(
    'priority',
  );
  @override
  late final GeneratedColumn<int> priority = GeneratedColumn<int>(
    'priority',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
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
  @override
  List<GeneratedColumn> get $columns => [
    id,
    title,
    keysJson,
    content,
    alwaysOn,
    enabled,
    priority,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'world_info_entries';
  @override
  VerificationContext validateIntegrity(
    Insertable<WorldInfoEntryRow> instance, {
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
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('keys_json')) {
      context.handle(
        _keysJsonMeta,
        keysJson.isAcceptableOrUnknown(data['keys_json']!, _keysJsonMeta),
      );
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    }
    if (data.containsKey('always_on')) {
      context.handle(
        _alwaysOnMeta,
        alwaysOn.isAcceptableOrUnknown(data['always_on']!, _alwaysOnMeta),
      );
    }
    if (data.containsKey('enabled')) {
      context.handle(
        _enabledMeta,
        enabled.isAcceptableOrUnknown(data['enabled']!, _enabledMeta),
      );
    }
    if (data.containsKey('priority')) {
      context.handle(
        _priorityMeta,
        priority.isAcceptableOrUnknown(data['priority']!, _priorityMeta),
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
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  WorldInfoEntryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return WorldInfoEntryRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      keysJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}keys_json'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      alwaysOn: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}always_on'],
      )!,
      enabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}enabled'],
      )!,
      priority: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}priority'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $WorldInfoEntriesTable createAlias(String alias) {
    return $WorldInfoEntriesTable(attachedDatabase, alias);
  }
}

class WorldInfoEntryRow extends DataClass
    implements Insertable<WorldInfoEntryRow> {
  final String id;
  final String title;
  final String keysJson;
  final String content;
  final bool alwaysOn;
  final bool enabled;
  final int priority;
  final DateTime createdAt;
  final DateTime updatedAt;
  const WorldInfoEntryRow({
    required this.id,
    required this.title,
    required this.keysJson,
    required this.content,
    required this.alwaysOn,
    required this.enabled,
    required this.priority,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['keys_json'] = Variable<String>(keysJson);
    map['content'] = Variable<String>(content);
    map['always_on'] = Variable<bool>(alwaysOn);
    map['enabled'] = Variable<bool>(enabled);
    map['priority'] = Variable<int>(priority);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  WorldInfoEntriesCompanion toCompanion(bool nullToAbsent) {
    return WorldInfoEntriesCompanion(
      id: Value(id),
      title: Value(title),
      keysJson: Value(keysJson),
      content: Value(content),
      alwaysOn: Value(alwaysOn),
      enabled: Value(enabled),
      priority: Value(priority),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory WorldInfoEntryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return WorldInfoEntryRow(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      keysJson: serializer.fromJson<String>(json['keysJson']),
      content: serializer.fromJson<String>(json['content']),
      alwaysOn: serializer.fromJson<bool>(json['alwaysOn']),
      enabled: serializer.fromJson<bool>(json['enabled']),
      priority: serializer.fromJson<int>(json['priority']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'keysJson': serializer.toJson<String>(keysJson),
      'content': serializer.toJson<String>(content),
      'alwaysOn': serializer.toJson<bool>(alwaysOn),
      'enabled': serializer.toJson<bool>(enabled),
      'priority': serializer.toJson<int>(priority),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  WorldInfoEntryRow copyWith({
    String? id,
    String? title,
    String? keysJson,
    String? content,
    bool? alwaysOn,
    bool? enabled,
    int? priority,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => WorldInfoEntryRow(
    id: id ?? this.id,
    title: title ?? this.title,
    keysJson: keysJson ?? this.keysJson,
    content: content ?? this.content,
    alwaysOn: alwaysOn ?? this.alwaysOn,
    enabled: enabled ?? this.enabled,
    priority: priority ?? this.priority,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  WorldInfoEntryRow copyWithCompanion(WorldInfoEntriesCompanion data) {
    return WorldInfoEntryRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      keysJson: data.keysJson.present ? data.keysJson.value : this.keysJson,
      content: data.content.present ? data.content.value : this.content,
      alwaysOn: data.alwaysOn.present ? data.alwaysOn.value : this.alwaysOn,
      enabled: data.enabled.present ? data.enabled.value : this.enabled,
      priority: data.priority.present ? data.priority.value : this.priority,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('WorldInfoEntryRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('keysJson: $keysJson, ')
          ..write('content: $content, ')
          ..write('alwaysOn: $alwaysOn, ')
          ..write('enabled: $enabled, ')
          ..write('priority: $priority, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    keysJson,
    content,
    alwaysOn,
    enabled,
    priority,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WorldInfoEntryRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.keysJson == this.keysJson &&
          other.content == this.content &&
          other.alwaysOn == this.alwaysOn &&
          other.enabled == this.enabled &&
          other.priority == this.priority &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class WorldInfoEntriesCompanion extends UpdateCompanion<WorldInfoEntryRow> {
  final Value<String> id;
  final Value<String> title;
  final Value<String> keysJson;
  final Value<String> content;
  final Value<bool> alwaysOn;
  final Value<bool> enabled;
  final Value<int> priority;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const WorldInfoEntriesCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.keysJson = const Value.absent(),
    this.content = const Value.absent(),
    this.alwaysOn = const Value.absent(),
    this.enabled = const Value.absent(),
    this.priority = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  WorldInfoEntriesCompanion.insert({
    required String id,
    required String title,
    this.keysJson = const Value.absent(),
    this.content = const Value.absent(),
    this.alwaysOn = const Value.absent(),
    this.enabled = const Value.absent(),
    this.priority = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<WorldInfoEntryRow> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? keysJson,
    Expression<String>? content,
    Expression<bool>? alwaysOn,
    Expression<bool>? enabled,
    Expression<int>? priority,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (keysJson != null) 'keys_json': keysJson,
      if (content != null) 'content': content,
      if (alwaysOn != null) 'always_on': alwaysOn,
      if (enabled != null) 'enabled': enabled,
      if (priority != null) 'priority': priority,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  WorldInfoEntriesCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<String>? keysJson,
    Value<String>? content,
    Value<bool>? alwaysOn,
    Value<bool>? enabled,
    Value<int>? priority,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return WorldInfoEntriesCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      keysJson: keysJson ?? this.keysJson,
      content: content ?? this.content,
      alwaysOn: alwaysOn ?? this.alwaysOn,
      enabled: enabled ?? this.enabled,
      priority: priority ?? this.priority,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
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
    if (keysJson.present) {
      map['keys_json'] = Variable<String>(keysJson.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (alwaysOn.present) {
      map['always_on'] = Variable<bool>(alwaysOn.value);
    }
    if (enabled.present) {
      map['enabled'] = Variable<bool>(enabled.value);
    }
    if (priority.present) {
      map['priority'] = Variable<int>(priority.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('WorldInfoEntriesCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('keysJson: $keysJson, ')
          ..write('content: $content, ')
          ..write('alwaysOn: $alwaysOn, ')
          ..write('enabled: $enabled, ')
          ..write('priority: $priority, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
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
  late final $CharacterCardsTable characterCards = $CharacterCardsTable(this);
  late final $WorldInfoEntriesTable worldInfoEntries = $WorldInfoEntriesTable(
    this,
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    conversations,
    messages,
    characterCards,
    worldInfoEntries,
  ];
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
      Value<String> mode,
      Value<String?> characterId,
      Value<String?> worldInfoIdsJson,
      Value<String> outline,
      Value<String> authorNote,
      Value<int> plotCursor,
      Value<String?> participantIdsJson,
      Value<String> venue,
      Value<int> nextSpeakerIndex,
      Value<String?> localCastJson,
      Value<int> rowid,
    });
typedef $$ConversationsTableUpdateCompanionBuilder =
    ConversationsCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<DateTime> updatedAt,
      Value<String?> activeChildrenJson,
      Value<String> mode,
      Value<String?> characterId,
      Value<String?> worldInfoIdsJson,
      Value<String> outline,
      Value<String> authorNote,
      Value<int> plotCursor,
      Value<String?> participantIdsJson,
      Value<String> venue,
      Value<int> nextSpeakerIndex,
      Value<String?> localCastJson,
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

  ColumnFilters<String> get mode => $composableBuilder(
    column: $table.mode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get characterId => $composableBuilder(
    column: $table.characterId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get worldInfoIdsJson => $composableBuilder(
    column: $table.worldInfoIdsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get outline => $composableBuilder(
    column: $table.outline,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get authorNote => $composableBuilder(
    column: $table.authorNote,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get plotCursor => $composableBuilder(
    column: $table.plotCursor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get participantIdsJson => $composableBuilder(
    column: $table.participantIdsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get venue => $composableBuilder(
    column: $table.venue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get nextSpeakerIndex => $composableBuilder(
    column: $table.nextSpeakerIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localCastJson => $composableBuilder(
    column: $table.localCastJson,
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

  ColumnOrderings<String> get mode => $composableBuilder(
    column: $table.mode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get characterId => $composableBuilder(
    column: $table.characterId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get worldInfoIdsJson => $composableBuilder(
    column: $table.worldInfoIdsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get outline => $composableBuilder(
    column: $table.outline,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get authorNote => $composableBuilder(
    column: $table.authorNote,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get plotCursor => $composableBuilder(
    column: $table.plotCursor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get participantIdsJson => $composableBuilder(
    column: $table.participantIdsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get venue => $composableBuilder(
    column: $table.venue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get nextSpeakerIndex => $composableBuilder(
    column: $table.nextSpeakerIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localCastJson => $composableBuilder(
    column: $table.localCastJson,
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

  GeneratedColumn<String> get mode =>
      $composableBuilder(column: $table.mode, builder: (column) => column);

  GeneratedColumn<String> get characterId => $composableBuilder(
    column: $table.characterId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get worldInfoIdsJson => $composableBuilder(
    column: $table.worldInfoIdsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get outline =>
      $composableBuilder(column: $table.outline, builder: (column) => column);

  GeneratedColumn<String> get authorNote => $composableBuilder(
    column: $table.authorNote,
    builder: (column) => column,
  );

  GeneratedColumn<int> get plotCursor => $composableBuilder(
    column: $table.plotCursor,
    builder: (column) => column,
  );

  GeneratedColumn<String> get participantIdsJson => $composableBuilder(
    column: $table.participantIdsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get venue =>
      $composableBuilder(column: $table.venue, builder: (column) => column);

  GeneratedColumn<int> get nextSpeakerIndex => $composableBuilder(
    column: $table.nextSpeakerIndex,
    builder: (column) => column,
  );

  GeneratedColumn<String> get localCastJson => $composableBuilder(
    column: $table.localCastJson,
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
                Value<String> mode = const Value.absent(),
                Value<String?> characterId = const Value.absent(),
                Value<String?> worldInfoIdsJson = const Value.absent(),
                Value<String> outline = const Value.absent(),
                Value<String> authorNote = const Value.absent(),
                Value<int> plotCursor = const Value.absent(),
                Value<String?> participantIdsJson = const Value.absent(),
                Value<String> venue = const Value.absent(),
                Value<int> nextSpeakerIndex = const Value.absent(),
                Value<String?> localCastJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationsCompanion(
                id: id,
                title: title,
                updatedAt: updatedAt,
                activeChildrenJson: activeChildrenJson,
                mode: mode,
                characterId: characterId,
                worldInfoIdsJson: worldInfoIdsJson,
                outline: outline,
                authorNote: authorNote,
                plotCursor: plotCursor,
                participantIdsJson: participantIdsJson,
                venue: venue,
                nextSpeakerIndex: nextSpeakerIndex,
                localCastJson: localCastJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                Value<String> title = const Value.absent(),
                required DateTime updatedAt,
                Value<String?> activeChildrenJson = const Value.absent(),
                Value<String> mode = const Value.absent(),
                Value<String?> characterId = const Value.absent(),
                Value<String?> worldInfoIdsJson = const Value.absent(),
                Value<String> outline = const Value.absent(),
                Value<String> authorNote = const Value.absent(),
                Value<int> plotCursor = const Value.absent(),
                Value<String?> participantIdsJson = const Value.absent(),
                Value<String> venue = const Value.absent(),
                Value<int> nextSpeakerIndex = const Value.absent(),
                Value<String?> localCastJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationsCompanion.insert(
                id: id,
                title: title,
                updatedAt: updatedAt,
                activeChildrenJson: activeChildrenJson,
                mode: mode,
                characterId: characterId,
                worldInfoIdsJson: worldInfoIdsJson,
                outline: outline,
                authorNote: authorNote,
                plotCursor: plotCursor,
                participantIdsJson: participantIdsJson,
                venue: venue,
                nextSpeakerIndex: nextSpeakerIndex,
                localCastJson: localCastJson,
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
      Value<String?> speakerId,
      Value<String?> speakerName,
      Value<String> kind,
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
      Value<String?> speakerId,
      Value<String?> speakerName,
      Value<String> kind,
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

  ColumnFilters<String> get speakerId => $composableBuilder(
    column: $table.speakerId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get speakerName => $composableBuilder(
    column: $table.speakerName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
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

  ColumnOrderings<String> get speakerId => $composableBuilder(
    column: $table.speakerId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get speakerName => $composableBuilder(
    column: $table.speakerName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
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

  GeneratedColumn<String> get speakerId =>
      $composableBuilder(column: $table.speakerId, builder: (column) => column);

  GeneratedColumn<String> get speakerName => $composableBuilder(
    column: $table.speakerName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

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
                Value<String?> speakerId = const Value.absent(),
                Value<String?> speakerName = const Value.absent(),
                Value<String> kind = const Value.absent(),
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
                speakerId: speakerId,
                speakerName: speakerName,
                kind: kind,
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
                Value<String?> speakerId = const Value.absent(),
                Value<String?> speakerName = const Value.absent(),
                Value<String> kind = const Value.absent(),
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
                speakerId: speakerId,
                speakerName: speakerName,
                kind: kind,
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
typedef $$CharacterCardsTableCreateCompanionBuilder =
    CharacterCardsCompanion Function({
      required String id,
      required String name,
      Value<String> description,
      Value<String> personality,
      Value<String> scenario,
      Value<String> firstMes,
      Value<String> exampleDialogs,
      Value<String> systemPrompt,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$CharacterCardsTableUpdateCompanionBuilder =
    CharacterCardsCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String> description,
      Value<String> personality,
      Value<String> scenario,
      Value<String> firstMes,
      Value<String> exampleDialogs,
      Value<String> systemPrompt,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$CharacterCardsTableFilterComposer
    extends Composer<_$AppDatabase, $CharacterCardsTable> {
  $$CharacterCardsTableFilterComposer({
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

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get personality => $composableBuilder(
    column: $table.personality,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get scenario => $composableBuilder(
    column: $table.scenario,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get firstMes => $composableBuilder(
    column: $table.firstMes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get exampleDialogs => $composableBuilder(
    column: $table.exampleDialogs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get systemPrompt => $composableBuilder(
    column: $table.systemPrompt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CharacterCardsTableOrderingComposer
    extends Composer<_$AppDatabase, $CharacterCardsTable> {
  $$CharacterCardsTableOrderingComposer({
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

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get personality => $composableBuilder(
    column: $table.personality,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scenario => $composableBuilder(
    column: $table.scenario,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get firstMes => $composableBuilder(
    column: $table.firstMes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get exampleDialogs => $composableBuilder(
    column: $table.exampleDialogs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get systemPrompt => $composableBuilder(
    column: $table.systemPrompt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CharacterCardsTableAnnotationComposer
    extends Composer<_$AppDatabase, $CharacterCardsTable> {
  $$CharacterCardsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );

  GeneratedColumn<String> get personality => $composableBuilder(
    column: $table.personality,
    builder: (column) => column,
  );

  GeneratedColumn<String> get scenario =>
      $composableBuilder(column: $table.scenario, builder: (column) => column);

  GeneratedColumn<String> get firstMes =>
      $composableBuilder(column: $table.firstMes, builder: (column) => column);

  GeneratedColumn<String> get exampleDialogs => $composableBuilder(
    column: $table.exampleDialogs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get systemPrompt => $composableBuilder(
    column: $table.systemPrompt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$CharacterCardsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $CharacterCardsTable,
          CharacterCardRow,
          $$CharacterCardsTableFilterComposer,
          $$CharacterCardsTableOrderingComposer,
          $$CharacterCardsTableAnnotationComposer,
          $$CharacterCardsTableCreateCompanionBuilder,
          $$CharacterCardsTableUpdateCompanionBuilder,
          (
            CharacterCardRow,
            BaseReferences<
              _$AppDatabase,
              $CharacterCardsTable,
              CharacterCardRow
            >,
          ),
          CharacterCardRow,
          PrefetchHooks Function()
        > {
  $$CharacterCardsTableTableManager(
    _$AppDatabase db,
    $CharacterCardsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CharacterCardsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CharacterCardsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CharacterCardsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> description = const Value.absent(),
                Value<String> personality = const Value.absent(),
                Value<String> scenario = const Value.absent(),
                Value<String> firstMes = const Value.absent(),
                Value<String> exampleDialogs = const Value.absent(),
                Value<String> systemPrompt = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CharacterCardsCompanion(
                id: id,
                name: name,
                description: description,
                personality: personality,
                scenario: scenario,
                firstMes: firstMes,
                exampleDialogs: exampleDialogs,
                systemPrompt: systemPrompt,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                Value<String> description = const Value.absent(),
                Value<String> personality = const Value.absent(),
                Value<String> scenario = const Value.absent(),
                Value<String> firstMes = const Value.absent(),
                Value<String> exampleDialogs = const Value.absent(),
                Value<String> systemPrompt = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => CharacterCardsCompanion.insert(
                id: id,
                name: name,
                description: description,
                personality: personality,
                scenario: scenario,
                firstMes: firstMes,
                exampleDialogs: exampleDialogs,
                systemPrompt: systemPrompt,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CharacterCardsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $CharacterCardsTable,
      CharacterCardRow,
      $$CharacterCardsTableFilterComposer,
      $$CharacterCardsTableOrderingComposer,
      $$CharacterCardsTableAnnotationComposer,
      $$CharacterCardsTableCreateCompanionBuilder,
      $$CharacterCardsTableUpdateCompanionBuilder,
      (
        CharacterCardRow,
        BaseReferences<_$AppDatabase, $CharacterCardsTable, CharacterCardRow>,
      ),
      CharacterCardRow,
      PrefetchHooks Function()
    >;
typedef $$WorldInfoEntriesTableCreateCompanionBuilder =
    WorldInfoEntriesCompanion Function({
      required String id,
      required String title,
      Value<String> keysJson,
      Value<String> content,
      Value<bool> alwaysOn,
      Value<bool> enabled,
      Value<int> priority,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$WorldInfoEntriesTableUpdateCompanionBuilder =
    WorldInfoEntriesCompanion Function({
      Value<String> id,
      Value<String> title,
      Value<String> keysJson,
      Value<String> content,
      Value<bool> alwaysOn,
      Value<bool> enabled,
      Value<int> priority,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

class $$WorldInfoEntriesTableFilterComposer
    extends Composer<_$AppDatabase, $WorldInfoEntriesTable> {
  $$WorldInfoEntriesTableFilterComposer({
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

  ColumnFilters<String> get keysJson => $composableBuilder(
    column: $table.keysJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get alwaysOn => $composableBuilder(
    column: $table.alwaysOn,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get priority => $composableBuilder(
    column: $table.priority,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$WorldInfoEntriesTableOrderingComposer
    extends Composer<_$AppDatabase, $WorldInfoEntriesTable> {
  $$WorldInfoEntriesTableOrderingComposer({
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

  ColumnOrderings<String> get keysJson => $composableBuilder(
    column: $table.keysJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get alwaysOn => $composableBuilder(
    column: $table.alwaysOn,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get priority => $composableBuilder(
    column: $table.priority,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$WorldInfoEntriesTableAnnotationComposer
    extends Composer<_$AppDatabase, $WorldInfoEntriesTable> {
  $$WorldInfoEntriesTableAnnotationComposer({
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

  GeneratedColumn<String> get keysJson =>
      $composableBuilder(column: $table.keysJson, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<bool> get alwaysOn =>
      $composableBuilder(column: $table.alwaysOn, builder: (column) => column);

  GeneratedColumn<bool> get enabled =>
      $composableBuilder(column: $table.enabled, builder: (column) => column);

  GeneratedColumn<int> get priority =>
      $composableBuilder(column: $table.priority, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$WorldInfoEntriesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $WorldInfoEntriesTable,
          WorldInfoEntryRow,
          $$WorldInfoEntriesTableFilterComposer,
          $$WorldInfoEntriesTableOrderingComposer,
          $$WorldInfoEntriesTableAnnotationComposer,
          $$WorldInfoEntriesTableCreateCompanionBuilder,
          $$WorldInfoEntriesTableUpdateCompanionBuilder,
          (
            WorldInfoEntryRow,
            BaseReferences<
              _$AppDatabase,
              $WorldInfoEntriesTable,
              WorldInfoEntryRow
            >,
          ),
          WorldInfoEntryRow,
          PrefetchHooks Function()
        > {
  $$WorldInfoEntriesTableTableManager(
    _$AppDatabase db,
    $WorldInfoEntriesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$WorldInfoEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$WorldInfoEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$WorldInfoEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> keysJson = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<bool> alwaysOn = const Value.absent(),
                Value<bool> enabled = const Value.absent(),
                Value<int> priority = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => WorldInfoEntriesCompanion(
                id: id,
                title: title,
                keysJson: keysJson,
                content: content,
                alwaysOn: alwaysOn,
                enabled: enabled,
                priority: priority,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                Value<String> keysJson = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<bool> alwaysOn = const Value.absent(),
                Value<bool> enabled = const Value.absent(),
                Value<int> priority = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => WorldInfoEntriesCompanion.insert(
                id: id,
                title: title,
                keysJson: keysJson,
                content: content,
                alwaysOn: alwaysOn,
                enabled: enabled,
                priority: priority,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$WorldInfoEntriesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $WorldInfoEntriesTable,
      WorldInfoEntryRow,
      $$WorldInfoEntriesTableFilterComposer,
      $$WorldInfoEntriesTableOrderingComposer,
      $$WorldInfoEntriesTableAnnotationComposer,
      $$WorldInfoEntriesTableCreateCompanionBuilder,
      $$WorldInfoEntriesTableUpdateCompanionBuilder,
      (
        WorldInfoEntryRow,
        BaseReferences<
          _$AppDatabase,
          $WorldInfoEntriesTable,
          WorldInfoEntryRow
        >,
      ),
      WorldInfoEntryRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ConversationsTableTableManager get conversations =>
      $$ConversationsTableTableManager(_db, _db.conversations);
  $$MessagesTableTableManager get messages =>
      $$MessagesTableTableManager(_db, _db.messages);
  $$CharacterCardsTableTableManager get characterCards =>
      $$CharacterCardsTableTableManager(_db, _db.characterCards);
  $$WorldInfoEntriesTableTableManager get worldInfoEntries =>
      $$WorldInfoEntriesTableTableManager(_db, _db.worldInfoEntries);
}
