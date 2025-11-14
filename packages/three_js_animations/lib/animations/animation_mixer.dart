import 'package:three_js_core/three_js_core.dart';
import 'package:three_js_math/three_js_math.dart';
import '../interpolants/index.dart';
import 'animation_action.dart';
import 'animation_clip.dart';
import 'keyframe_track.dart';
import 'property_mixer.dart';
import 'property_binding.dart';

/// The AnimationMixer is a player for animations on a particular object in
/// the scene. When multiple objects in the scene are animated independently,
/// one AnimationMixer may be used for each object.
class AnimationMixer with EventDispatcher {
  num time = 0.0;
  num timeScale = 1.0;

  Object3D root;
  int _accuIndex = 0;

  late List<AnimationAction> _actions;
  late int _nActiveActions;
  // Typed bucket: clipUuid -> { "knownActions": List<AnimationAction>, "actionByRoot": Map<String, AnimationAction> }
  late Map<String, Map<String, dynamic>> actionsByClip;
  late List<PropertyMixer> bindings;
  late int _nActiveBindings;
  late Map<String, Map<String, PropertyMixer>> bindingsByRootAndName;
  late List _controlInterpolants;
  late int _nActiveControlInterpolants;

  final _controlInterpolantsResultBuffer = List<num>.filled(1, 0);

  Map<String, dynamic>? stats;

  AnimationMixer(this.root) {
    _initMemoryManager();
  }

  void _bindAction(AnimationAction action, AnimationAction? prototypeAction) {
    final root = action.localRoot ?? this.root;
    final List<KeyframeTrack> tracks = action.clip.tracks;
    final nTracks = tracks.length,
        bindings = action.propertyBindings,
        interpolants = action.interpolants,
        rootUuid = root.uuid,
        bindingsByRoot = bindingsByRootAndName;

    Map<String, PropertyMixer>? bindingsByName = bindingsByRoot[rootUuid];

    if (bindingsByName == null) {
      bindingsByName = {};
      bindingsByRoot[rootUuid] = bindingsByName;
    }

    for (int i = 0; i != nTracks; ++i) {
      final track = tracks[i], trackName = track.name;

      PropertyMixer? binding = bindingsByName[trackName];

      if (binding != null) {
        ++binding.referenceCount;
        bindings[i] = binding;
      } else {
        binding = bindings[i];

        if (binding != null) {
          if (binding.cacheIndex == null) {
            ++binding.referenceCount;
            _addInactiveBinding(binding, rootUuid, trackName);
          }
          continue;
        }

        final path = prototypeAction?.propertyBindings[i]?.binding.parsedPath;

        binding = PropertyMixer(
          PropertyBinding.create(root, trackName, path) as PropertyBinding,
          track.valueTypeName,
          track.getValueSize(),
        );

        ++binding.referenceCount;
        _addInactiveBinding(binding, rootUuid, trackName);

        bindings[i] = binding;
      }

      interpolants[i]?.resultBuffer = binding.buffer;
    }
  }

  void activateAction(AnimationAction action) {
    if (!isActiveAction(action)) {
      if (action.cacheIndex == null) {
        final rootUuid = (action.localRoot ?? root).uuid;
        final clipUuid = action.clip.uuid;

        final Map<String, dynamic>? afc =
            actionsByClip[clipUuid] as Map<String, dynamic>?;
        AnimationAction? proto;
        if (afc != null) {
          final List<AnimationAction> known =
              (afc['knownActions'] as List?)?.cast<AnimationAction>() ??
              const [];
          proto = known.isNotEmpty ? known[0] : null;
        }

        _bindAction(action, proto);
        _addInactiveAction(action, clipUuid, rootUuid);
      }

      final bindings = action.propertyBindings;
      for (int i = 0, n = bindings.length; i != n; ++i) {
        final binding = bindings[i]!;
        if (binding.useCount++ == 0) {
          _lendBinding(binding);
          binding.saveOriginalState();
        }
      }
      _lendAction(action);
    }
  }

  void deactivateAction(AnimationAction action) {
    if (isActiveAction(action)) {
      final bindings = action.propertyBindings;
      for (int i = 0, n = bindings.length; i != n; ++i) {
        final b = bindings[i];
        if (b != null) {
          if (--b.useCount == 0) {
            b.restoreOriginalState();
            _takeBackBinding(b);
          }
        }
      }
      _takeBackAction(action);
    }
  }

  // ---------------- Memory manager ----------------

  void _initMemoryManager() {
    _actions = [];
    _nActiveActions = 0;

    actionsByClip = {};

    bindings = [];
    _nActiveBindings = 0;

    bindingsByRootAndName = {};

    _controlInterpolants = [];
    _nActiveControlInterpolants = 0;

    stats = {
      'actions': {
        'total': () => _actions.length,
        'inUse': () => _nActiveActions,
      },
      'bindings': {
        'total': () => bindings.length,
        'inUse': () => _nActiveBindings,
      },
      'controlInterpolants': {
        'total': () => _controlInterpolants.length,
        'inUse': () => _nActiveControlInterpolants,
      },
    };
  }

  bool isActiveAction(AnimationAction action) {
    final index = action.cacheIndex;
    return index != null && index < _nActiveActions;
  }

  void _addInactiveAction(
    AnimationAction action,
    String clipUuid,
    String rootUuid,
  ) {
    final actions = _actions;
    final actionsByClip = this.actionsByClip;

    Map<String, dynamic>? actionsForClip = actionsByClip[clipUuid];

    if (actionsForClip == null) {
      actionsForClip = {
        "knownActions": <AnimationAction>[],
        "actionByRoot": <String, AnimationAction>{},
      };
      actionsByClip[clipUuid] = actionsForClip;
    }

    final known = actionsForClip["knownActions"] as List<AnimationAction>;
    action.byClipCacheIndex = known.length;
    known.add(action);

    action.cacheIndex = actions.length;
    actions.add(action);

    final actionByRoot =
        actionsForClip["actionByRoot"] as Map<String, AnimationAction>;
    actionByRoot[rootUuid] = action;
  }

  void _removeInactiveAction(AnimationAction action) {
    final actions = _actions;
    final lastInactiveAction = actions[actions.length - 1];
    final cacheIndex = action.cacheIndex!;

    lastInactiveAction.cacheIndex = cacheIndex;
    actions[cacheIndex] = lastInactiveAction;
    actions.removeLast();

    action.cacheIndex = null;

    final clipUuid = action.clip.uuid;
    final actionsForClip = actionsByClip[clipUuid]!;
    final known = actionsForClip['knownActions'] as List<AnimationAction>;
    final lastKnownAction = known[known.length - 1];
    final byClipCacheIndex = action.byClipCacheIndex ?? 0;

    lastKnownAction.byClipCacheIndex = byClipCacheIndex;
    known[byClipCacheIndex] = lastKnownAction;
    known.removeLast();

    action.byClipCacheIndex = null;

    final actionByRoot =
        actionsForClip['actionByRoot'] as Map<String, AnimationAction>;
    final rootUuid = (action.localRoot ?? root).uuid;
    actionByRoot.remove(rootUuid);

    if (known.isEmpty) {
      actionsByClip.remove(clipUuid);
    }

    _removeInactiveBindingsForAction(action);
  }

  void _removeInactiveBindingsForAction(AnimationAction action) {
    final bindings = action.propertyBindings;
    for (int i = 0, n = bindings.length; i != n; ++i) {
      final binding = bindings[i];
      if (binding != null && --binding.referenceCount == 0) {
        _removeInactiveBinding(binding);
      }
    }
  }

  void _lendAction(AnimationAction action) {
    final actions = _actions,
        prevIndex = action.cacheIndex!,
        lastActiveIndex = _nActiveActions++,
        firstInactiveAction = actions[lastActiveIndex];

    action.cacheIndex = lastActiveIndex;
    actions[lastActiveIndex] = action;

    firstInactiveAction.cacheIndex = prevIndex;
    actions[prevIndex] = firstInactiveAction;
  }

  void _takeBackAction(AnimationAction action) {
    final actions = _actions,
        prevIndex = action.cacheIndex!,
        firstInactiveIndex = --_nActiveActions,
        lastActiveAction = actions[firstInactiveIndex];

    action.cacheIndex = firstInactiveIndex;
    actions[firstInactiveIndex] = action;

    lastActiveAction.cacheIndex = prevIndex;
    actions[prevIndex] = lastActiveAction;
  }

  void _addInactiveBinding(
    PropertyMixer binding,
    String rootUuid,
    String trackName,
  ) {
    final bindingsByRoot = bindingsByRootAndName, bindings = this.bindings;

    Map<String, PropertyMixer>? bindingByName = bindingsByRoot[rootUuid];
    if (bindingByName == null) {
      bindingByName = {};
      bindingsByRoot[rootUuid] = bindingByName;
    }

    bindingByName[trackName] = binding;

    binding.cacheIndex = bindings.length;
    bindings.add(binding);
  }

  void _removeInactiveBinding(PropertyMixer binding) {
    final bindings = this.bindings,
        propBinding = binding.binding,
        rootUuid = propBinding.rootNode?.uuid,
        trackName = propBinding.path,
        bindingsByRoot = bindingsByRootAndName,
        bindingByName = bindingsByRoot[rootUuid],
        lastInactiveBinding = bindings[bindings.length - 1],
        cacheIndex = binding.cacheIndex!;

    lastInactiveBinding.cacheIndex = cacheIndex;
    bindings[cacheIndex] = lastInactiveBinding;
    bindings.removeLast();

    bindingByName?.remove(trackName);

    if (bindingByName != null && bindingByName.keys.isEmpty) {
      bindingsByRoot.remove(rootUuid);
    }
  }

  void _lendBinding(PropertyMixer binding) {
    final bindings = this.bindings,
        prevIndex = binding.cacheIndex!,
        lastActiveIndex = _nActiveBindings++,
        firstInactiveBinding = bindings[lastActiveIndex];

    binding.cacheIndex = lastActiveIndex;
    bindings[lastActiveIndex] = binding;

    firstInactiveBinding.cacheIndex = prevIndex;
    bindings[prevIndex] = firstInactiveBinding;
  }

  void _takeBackBinding(PropertyMixer binding) {
    final bindings = this.bindings,
        prevIndex = binding.cacheIndex!,
        firstInactiveIndex = --_nActiveBindings,
        lastActiveBinding = bindings[firstInactiveIndex];

    binding.cacheIndex = firstInactiveIndex;
    bindings[firstInactiveIndex] = binding;

    lastActiveBinding.cacheIndex = prevIndex;
    bindings[prevIndex] = lastActiveBinding;
  }

  // ------------- Control interpolants -------------

  Interpolant lendControlInterpolant() {
    final interpolants = _controlInterpolants,
        lastActiveIndex = _nActiveControlInterpolants++;

    Interpolant? interpolant = interpolants.length > lastActiveIndex
        ? interpolants[lastActiveIndex]
        : null;

    if (interpolant == null) {
      console.info(" AnimationMixer LinearInterpolant init todo");
      interpolant = LinearInterpolant(
        List<num>.filled(2, 0),
        List<num>.filled(2, 0),
        1,
        _controlInterpolantsResultBuffer,
      );

      interpolant.cachedIndex = lastActiveIndex;
      interpolants.listSetter(lastActiveIndex, interpolant);
    }

    return interpolant;
  }

  void takeBackControlInterpolant(Interpolant interpolant) {
    final interpolants = _controlInterpolants,
        prevIndex = interpolant.cachedIndex,
        firstInactiveIndex = --_nActiveControlInterpolants,
        lastActiveInterpolant = interpolants[firstInactiveIndex];

    interpolant.cachedIndex = firstInactiveIndex;
    interpolants.listSetter(firstInactiveIndex, interpolant);

    lastActiveInterpolant.cachedIndex = prevIndex;
    interpolants.listSetter(prevIndex, lastActiveInterpolant);
  }

  // ------------- Public API -------------

  /// Returns an AnimationAction for the passed clip (AnimationClip or String),
  /// optionally using a custom root and blendMode.
  AnimationAction? clipAction(
    dynamic clip, [
    Object3D? optionalRoot,
    int? blendMode,
  ]) {
    final root = optionalRoot ?? this.root;
    final rootUuid = root.uuid;

    AnimationClip? clipObject;
    if (clip is AnimationClip) {
      clipObject = clip;
    } else if (clip is String) {
      // Try to grab animations from the root
      List<AnimationClip> pool = const [];
      try {
        final dyn = root as dynamic;
        final maybe = dyn.animations;
        if (maybe is List) pool = maybe.cast<AnimationClip>();
      } catch (_) {}
      clipObject = AnimationClip.findByName(pool, clip);
      if (clipObject == null) return null;
    } else {
      return null;
    }

    final clipUuid = clipObject.uuid;
    final afc = actionsByClip[clipUuid];

    blendMode ??= (clipObject.blendMode ?? NormalAnimationBlendMode);

    if (afc != null) {
      final actionByRoot =
          (afc['actionByRoot'] as Map<String, AnimationAction>?);
      final existing = actionByRoot?[rootUuid];
      if (existing != null && existing.blendMode == blendMode) {
        return existing;
      }
    }

    final newAction = AnimationAction(
      this,
      clipObject,
      localRoot: optionalRoot,
      blendMode: blendMode,
    );

    _bindAction(newAction, null);
    _addInactiveAction(newAction, clipUuid, rootUuid);
    return newAction;
  }

  /// Returns an existing action if present.
  AnimationAction? existingAction(
    AnimationClip clip, [
    Object3D? optionalRoot,
  ]) {
    final root = optionalRoot ?? this.root;
    final rootUuid = root.uuid;

    final actionsForClip = actionsByClip[clip.uuid];
    if (actionsForClip == null) return null;

    final actionByRoot =
        actionsForClip['actionByRoot'] as Map<String, AnimationAction>?;
    return actionByRoot?[rootUuid];
  }

  /// Deactivates all previously scheduled actions on this mixer.
  AnimationMixer stopAllAction() {
    final actions = _actions, nActions = _nActiveActions;
    for (int i = nActions - 1; i >= 0; --i) {
      actions[i].stop();
    }
    return this;
  }

  /// Advance time and apply the animation. Call from your render loop.
  AnimationMixer update(num deltaTime) {
    deltaTime *= timeScale;

    final actions = _actions,
        nActions = _nActiveActions,
        time = this.time += deltaTime,
        timeDirection = deltaTime.toDouble().sign,
        accuIndex = _accuIndex ^= 1;

    for (int i = 0; i != nActions; ++i) {
      final action = actions[i];
      action.update(time, deltaTime, timeDirection, accuIndex);
    }

    final bindings = this.bindings;
    final nBindings = _nActiveBindings;

    for (int i = 0; i != nBindings; ++i) {
      final binding = bindings[i];
      binding.apply(accuIndex);
    }

    return this;
  }

  /// Seek to a specific time in seconds.
  AnimationMixer setTime(num timeInSeconds) {
    time = 0;
    for (int i = 0; i < _actions.length; i++) {
      _actions[i].time = 0;
    }
    return update(timeInSeconds);
  }

  Object3D getRoot() => root;

  /// Free all memory for a clip. Call `action.stop()` first.
  void uncacheClip(AnimationClip clip) {
    final actions = _actions;
    final actionsForClip = actionsByClip[clip.uuid];
    if (actionsForClip == null) return;

    final known = actionsForClip['knownActions'] as List<AnimationAction>?;
    if (known == null || known.isEmpty) {
      actionsByClip.remove(clip.uuid);
      return;
    }

    for (final action in known) {
      deactivateAction(action);

      final cacheIndex = action.cacheIndex!;
      final lastInactiveAction = actions[actions.length - 1];

      action.cacheIndex = null;
      action.byClipCacheIndex = null;

      lastInactiveAction.cacheIndex = cacheIndex;
      actions[cacheIndex] = lastInactiveAction;
      actions.removeLast();

      _removeInactiveBindingsForAction(action);
    }

    actionsByClip.remove(clip.uuid);
  }

  /// Free all memory for a root object. Call `action.stop()` first.
  void uncacheRoot(Object3D root) {
    final rootUuid = root.uuid;

    actionsByClip.forEach((clipUuid, bucket) {
      final actionByRoot =
          (bucket['actionByRoot'] as Map<String, AnimationAction>?);
      final action = actionByRoot?[rootUuid];
      if (action != null) {
        deactivateAction(action);
        _removeInactiveAction(action);
      }
    });

    final bindingByName = bindingsByRootAndName[rootUuid];
    if (bindingByName != null) {
      for (final entry in bindingByName.entries.toList()) {
        entry.value.restoreOriginalState();
        _removeInactiveBinding(entry.value);
      }
    }
  }

  /// Free all memory for a specific action (by clip/root). Call `action.stop()` first.
  void uncacheAction(AnimationClip clip, [Object3D? optionalRoot]) {
    final action = existingAction(clip, optionalRoot);
    if (action != null) {
      deactivateAction(action);
      _removeInactiveAction(action);
    }
  }
}
