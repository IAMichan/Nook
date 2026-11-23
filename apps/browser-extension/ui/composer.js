// node_modules/svelte/src/constants.js
var HYDRATION_ERROR = {};
var UNINITIALIZED = Symbol("uninitialized");
var NAMESPACE_HTML = "http://www.w3.org/1999/xhtml";
var NAMESPACE_SVG = "http://www.w3.org/2000/svg";
var NAMESPACE_MATHML = "http://www.w3.org/1998/Math/MathML";
// node_modules/svelte/src/internal/shared/utils.js
var is_array = Array.isArray;
var index_of = Array.prototype.indexOf;
var includes = Array.prototype.includes;
var array_from = Array.from;
var define_property = Object.defineProperty;
var get_descriptor = Object.getOwnPropertyDescriptor;
var get_descriptors = Object.getOwnPropertyDescriptors;
var object_prototype = Object.prototype;
var array_prototype = Array.prototype;
var get_prototype_of = Object.getPrototypeOf;
var is_extensible = Object.isExtensible;
var noop = () => {};
/** @param {Array<() => void>} arr */
function run_all(arr) {
	for (var i = 0; i < arr.length; i++) arr[i]();
}
/**
* TODO replace with Promise.withResolvers once supported widely enough
* @template [T=void]
*/
function deferred() {
	/** @type {(value: T) => void} */
	var resolve;
	/** @type {(reason: any) => void} */
	var reject;
	return {
		promise: new Promise((res, rej) => {
			resolve = res;
			reject = rej;
		}),
		resolve,
		reject
	};
}
var CLEAN = 1024;
var DIRTY = 2048;
var MAYBE_DIRTY = 4096;
var INERT = 8192;
var DESTROYED = 16384;
/** Set once a reaction has run for the first time */
var REACTION_RAN = 32768;
/** Effect is in the process of getting destroyed. Can be observed in child teardown functions */
var DESTROYING = 1 << 25;
/**
* 'Transparent' effects do not create a transition boundary.
* This is on a block effect 99% of the time but may also be on a branch effect if its parent block effect was pruned
*/
var EFFECT_TRANSPARENT = 65536;
var EFFECT_PRESERVED = 1 << 19;
var USER_EFFECT = 1 << 20;
var EFFECT_OFFSCREEN = 1 << 25;
var REACTION_IS_UPDATING = 1 << 21;
var ASYNC = 1 << 22;
var ERROR_VALUE = 1 << 23;
var STATE_SYMBOL = Symbol("$state");
/** Marks component export objects, so that `proxy(...)` leaves them untouched */
var COMPONENT_SYMBOL = Symbol("component");
var LEGACY_PROPS = Symbol("legacy props");
var LOADING_ATTR_SYMBOL = Symbol("");
var ATTRIBUTES_CACHE = Symbol("attributes");
var CLASS_CACHE = Symbol("class");
var STYLE_CACHE = Symbol("style");
var TEXT_CACHE = Symbol("text");
var FORM_RESET_HANDLER = Symbol("form reset");
/** allow users to ignore aborted signal errors if `reason.name === 'StaleReactionError` */
var STALE_REACTION = new class StaleReactionError extends Error {
	name = "StaleReactionError";
	message = "The reaction that called `getAbortSignal()` was re-run or destroyed";
}();
var IS_XHTML = !!globalThis.document?.contentType && /* @__PURE__ */ globalThis.document.contentType.includes("xml");
/**
* Reading a derived belonging to a now-destroyed effect may result in stale values
*/
function derived_inert() {
	console.warn(`https://svelte.dev/e/derived_inert`);
}
/**
* Hydration failed because the initial UI does not match what was rendered on the server. The error occurred near %location%
* @param {string | undefined | null} [location]
*/
function hydration_mismatch(location) {
	console.warn(`https://svelte.dev/e/hydration_mismatch`);
}
/**
* A `<svelte:boundary>` `reset` function only resets the boundary the first time it is called
*/
function svelte_boundary_reset_noop() {
	console.warn(`https://svelte.dev/e/svelte_boundary_reset_noop`);
}
// node_modules/svelte/src/internal/client/dom/hydration.js
/** @import { TemplateNode } from '#client' */
/**
* Use this variable to guard everything related to hydration code so it can be treeshaken out
* if the user doesn't use the `hydrate` method and these code paths are therefore not needed.
*/
var hydrating = false;
/** @param {boolean} value */
function set_hydrating(value) {
	hydrating = value;
}
/**
* The node that is currently being hydrated. This starts out as the first node inside the opening
* <!--[--> comment, and updates each time a component calls `$.child(...)` or `$.sibling(...)`.
* When entering a block (e.g. `{#if ...}`), `hydrate_node` is the block opening comment; by the
* time we leave the block it is the closing comment, which serves as the block's anchor.
* @type {TemplateNode}
*/
var hydrate_node;
/** @param {TemplateNode | null} node */
function set_hydrate_node(node) {
	if (node === null) {
		hydration_mismatch();
		throw HYDRATION_ERROR;
	}
	return hydrate_node = node;
}
function hydrate_next() {
	return set_hydrate_node(/* @__PURE__ */ get_next_sibling(hydrate_node));
}
/** @param {TemplateNode} node */
function reset(node) {
	if (!hydrating) return;
	if (/* @__PURE__ */ get_next_sibling(hydrate_node) !== null) {
		hydration_mismatch();
		throw HYDRATION_ERROR;
	}
	hydrate_node = node;
}
function next$1(count = 1) {
	if (hydrating) {
		var i = count;
		var node = hydrate_node;
		while (i--) node = /* @__PURE__ */ get_next_sibling(node);
		hydrate_node = node;
	}
}
/**
* Skips or removes (depending on {@link remove}) all nodes starting at `hydrate_node` up until the next hydration end comment
* @param {boolean} remove
*/
function skip_nodes(remove = true) {
	var depth = 0;
	var node = hydrate_node;
	while (true) {
		if (node.nodeType === 8) {
			var data = node.data;
			if (data === "]") {
				if (depth === 0) return node;
				depth -= 1;
			} else if (data === "[" || data === "[!" || data[0] === "[" && !isNaN(Number(data.slice(1)))) depth += 1;
		}
		var next = /* @__PURE__ */ get_next_sibling(node);
		if (remove) node.remove();
		node = next;
	}
}
/**
*
* @param {TemplateNode} node
*/
function read_hydration_instruction(node) {
	if (!node || node.nodeType !== 8) {
		hydration_mismatch();
		throw HYDRATION_ERROR;
	}
	return node.data;
}
// node_modules/svelte/src/internal/client/reactivity/equality.js
/** @import { Equals } from '#client' */
/** @type {Equals} */
function equals(value) {
	return value === this.v;
}
/**
* @param {unknown} a
* @param {unknown} b
* @returns {boolean}
*/
function safe_not_equal(a, b) {
	return a != a ? b == b : a !== b || a !== null && typeof a === "object" || typeof a === "function";
}
/** @type {Equals} */
function safe_equals(value) {
	return !safe_not_equal(value, this.v);
}
// node_modules/svelte/src/internal/client/errors.js
/**
* Cannot create a `$derived(...)` with an `await` expression outside of an effect tree
* @returns {never}
*/
function async_derived_orphan() {
	throw new Error(`https://svelte.dev/e/async_derived_orphan`);
}
/**
* Keyed each block has duplicate key `%value%` at indexes %a% and %b%
* @param {string} a
* @param {string} b
* @param {string | undefined | null} [value]
* @returns {never}
*/
function each_key_duplicate(a, b, value) {
	throw new Error(`https://svelte.dev/e/each_key_duplicate`);
}
/**
* `%rune%` cannot be used inside an effect cleanup function
* @param {string} rune
* @returns {never}
*/
function effect_in_teardown(rune) {
	throw new Error(`https://svelte.dev/e/effect_in_teardown`);
}
/**
* Effect cannot be created inside a `$derived` value that was not itself created inside an effect
* @returns {never}
*/
function effect_in_unowned_derived() {
	throw new Error(`https://svelte.dev/e/effect_in_unowned_derived`);
}
/**
* `%rune%` can only be used inside an effect (e.g. during component initialisation)
* @param {string} rune
* @returns {never}
*/
function effect_orphan(rune) {
	throw new Error(`https://svelte.dev/e/effect_orphan`);
}
/**
* Maximum update depth exceeded. This typically indicates that an effect reads and writes the same piece of state
* @returns {never}
*/
function effect_update_depth_exceeded() {
	throw new Error(`https://svelte.dev/e/effect_update_depth_exceeded`);
}
/**
* Cannot do `bind:%key%={undefined}` when `%key%` has a fallback value
* @param {string} key
* @returns {never}
*/
function props_invalid_value(key) {
	throw new Error(`https://svelte.dev/e/props_invalid_value`);
}
/**
* Property descriptors defined on `$state` objects must contain `value` and always be `enumerable`, `configurable` and `writable`.
* @returns {never}
*/
function state_descriptors_fixed() {
	throw new Error(`https://svelte.dev/e/state_descriptors_fixed`);
}
/**
* Cannot set prototype of `$state` object
* @returns {never}
*/
function state_prototype_fixed() {
	throw new Error(`https://svelte.dev/e/state_prototype_fixed`);
}
/**
* Updating state inside `$derived(...)`, `$inspect(...)` or a template expression is forbidden. If the value should not be reactive, declare it without `$state`
* @returns {never}
*/
function state_unsafe_mutation() {
	throw new Error(`https://svelte.dev/e/state_unsafe_mutation`);
}
/**
* A `<svelte:boundary>` `reset` function cannot be called while an error is still being handled
* @returns {never}
*/
function svelte_boundary_reset_onerror() {
	throw new Error(`https://svelte.dev/e/svelte_boundary_reset_onerror`);
}
// node_modules/svelte/src/internal/flags/index.js
/** True if experimental.async=true */
var async_mode_flag = false;
/** True if we're not certain that we only have Svelte 5 code in the compilation */
var legacy_mode_flag = false;
// node_modules/svelte/src/internal/client/context.js
/** @import { ComponentContext, DevStackEntry, Effect } from '#client' */
/** @type {ComponentContext | null} */
var component_context = null;
/** @param {ComponentContext | null} context */
function set_component_context(context) {
	component_context = context;
}
/**
* @param {Record<string, unknown>} props
* @param {any} runes
* @param {Function} [fn]
* @returns {void}
*/
function push(props, runes = false, fn) {
	component_context = {
		p: component_context,
		i: false,
		c: null,
		e: null,
		s: props,
		x: null,
		r: active_effect,
		l: legacy_mode_flag && !runes ? {
			s: null,
			u: null,
			$: []
		} : null
	};
}
/**
* @template {Record<string, any>} T
* @param {T} [component]
* @returns {T}
*/
function pop(component) {
	var context = component_context;
	var effects = context.e;
	if (effects !== null) {
		context.e = null;
		for (var fn of effects) create_user_effect(fn);
	}
	if (component !== void 0) context.x = component;
	context.i = true;
	component_context = context.p;
	return mark_as_component(component);
}
/**
* Add a symbol to the object (or create one if undefined) to mark it as a component so it isn't proxified.
* @param {any} component
*/
function mark_as_component(component = {}) {
	define_property(component, COMPONENT_SYMBOL, { value: true });
	return component;
}
/** @returns {boolean} */
function is_runes() {
	return !legacy_mode_flag || component_context !== null && component_context.l === null;
}
// node_modules/svelte/src/internal/client/dom/task.js
/** @type {Array<() => void>} */
var micro_tasks = [];
function run_micro_tasks() {
	var tasks = micro_tasks;
	micro_tasks = [];
	run_all(tasks);
}
/**
* @param {() => void} fn
*/
function queue_micro_task(fn) {
	if (micro_tasks.length === 0 && !is_flushing_sync) {
		var tasks = micro_tasks;
		queueMicrotask(() => {
			if (tasks === micro_tasks) run_micro_tasks();
		});
	}
	micro_tasks.push(fn);
}
/**
* Synchronously run any queued tasks.
*/
function flush_tasks() {
	while (micro_tasks.length > 0) run_micro_tasks();
}
// node_modules/svelte/src/internal/client/reactivity/status.js
/** @import { Derived, Signal } from '#client' */
var STATUS_MASK = ~(DIRTY | MAYBE_DIRTY | CLEAN);
/**
* @param {Signal} signal
* @param {number} status
*/
function set_signal_status(signal, status) {
	signal.f = signal.f & STATUS_MASK | status;
}
/**
* Set a derived's status to CLEAN or MAYBE_DIRTY based on its connection state.
* @param {Derived} derived
*/
function update_derived_status(derived) {
	if ((derived.f & 512) !== 0 || derived.deps === null) set_signal_status(derived, CLEAN);
	else set_signal_status(derived, MAYBE_DIRTY);
}
// node_modules/svelte/src/internal/client/reactivity/utils.js
/** @import { Effect } from '#client' */
/**
* @param {Effect} effect
* @param {Map<Effect, number>} dirty_reactions
*/
function defer_effect(effect, dirty_reactions) {
	if ((effect.f & 2048) !== 0) dirty_reactions.set(effect, DIRTY);
	else if ((effect.f & 4096) !== 0 && dirty_reactions.get(effect) !== 2048) dirty_reactions.set(effect, MAYBE_DIRTY);
	set_signal_status(effect, CLEAN);
}
// node_modules/svelte/src/internal/client/dom/elements/misc.js
/**
* The child of a textarea actually corresponds to the defaultValue property, so we need
* to remove it upon hydration to avoid a bug when someone resets the form value.
* @param {HTMLTextAreaElement} dom
* @returns {void}
*/
function remove_textarea_child(dom) {
	if (hydrating && /* @__PURE__ */ get_first_child(dom) !== null) clear_text_content(dom);
}
var listening_to_form_reset = false;
function add_form_reset_listener() {
	if (!listening_to_form_reset) {
		listening_to_form_reset = true;
		document.addEventListener("reset", (evt) => {
			Promise.resolve().then(() => {
				if (!evt.defaultPrevented) for (const e of evt.target.elements)
 /** @type {any} */ e[FORM_RESET_HANDLER]?.();
			});
		}, { capture: true });
	}
}
// node_modules/svelte/src/internal/client/dom/elements/bindings/shared.js
/**
* @template T
* @param {() => T} fn
*/
function without_reactive_context(fn) {
	var previous_reaction = active_reaction;
	var previous_effect = active_effect;
	set_active_reaction(null);
	set_active_effect(null);
	try {
		return fn();
	} finally {
		set_active_reaction(previous_reaction);
		set_active_effect(previous_effect);
	}
}
/**
* Listen to the given event, and then instantiate a global form reset listener if not already done,
* to notify all bindings when the form is reset
* @param {HTMLElement} element
* @param {string} event
* @param {(is_reset?: true) => void} handler
* @param {(is_reset?: true) => void} [on_reset]
*/
function listen_to_event_and_reset_event(element, event, handler, on_reset = handler) {
	element.addEventListener(event, () => without_reactive_context(handler));
	const prev = element[FORM_RESET_HANDLER];
	if (prev)
 /** @type {any} */ element[FORM_RESET_HANDLER] = () => {
		prev();
		on_reset(true);
	};
	else
 /** @type {any} */ element[FORM_RESET_HANDLER] = () => on_reset(true);
	add_form_reset_listener();
}
// node_modules/svelte/src/internal/client/reactivity/async.js
/** @import { Blocker, Effect, Source, Value } from '#client' */
/**
* @param {Blocker[]} blockers
* @param {Array<() => any>} sync
* @param {Array<() => Promise<any>>} async
* @param {(values: Value[]) => any} fn
*/
function flatten(blockers, sync, async, fn) {
	const d = is_runes() ? derived : derived_safe_equal;
	var pending = blockers.filter((b) => !b.settled);
	var deriveds = sync.map(d);
	if (async.length === 0 && pending.length === 0) {
		fn(deriveds);
		return;
	}
	var parent = active_effect;
	var restore = capture();
	var blocker_promise = pending.length === 1 ? pending[0].promise : pending.length > 1 ? Promise.all(pending.map((b) => b.promise)) : null;
	/**
	* @param {Source[]} async
	*/
	function finish(async) {
		if ((parent.f & 16384) !== 0) return;
		restore();
		try {
			fn([...deriveds, ...async]);
		} catch (error) {
			invoke_error_boundary(error, parent);
		}
		unset_context();
	}
	var decrement_pending = increment_pending();
	if (async.length === 0) {
		/** @type {Promise<any>} */ blocker_promise.then(() => finish([])).finally(decrement_pending);
		return;
	}
	function run() {
		Promise.all(async.map((expression) => /* @__PURE__ */ async_derived(expression))).then(finish).catch((error) => invoke_error_boundary(error, parent)).finally(decrement_pending);
	}
	if (blocker_promise) blocker_promise.then(() => {
		if ((parent.f & 16384) !== 0) {
			decrement_pending();
			return;
		}
		restore();
		run();
		unset_context();
	});
	else run();
}
/**
* Captures the current effect context so that we can restore it after
* some asynchronous work has happened (so that e.g. `await a + b`
* causes `b` to be registered as a dependency).
*/
function capture() {
	var previous_effect = active_effect;
	var previous_reaction = active_reaction;
	var previous_component_context = component_context;
	var previous_batch = current_batch;
	return function restore(activate_batch = true) {
		set_active_effect(previous_effect);
		set_active_reaction(previous_reaction);
		set_component_context(previous_component_context);
		if (activate_batch && (previous_effect.f & 16384) === 0) {
			previous_batch?.activate();
			previous_batch?.apply();
		}
	};
}
function unset_context(deactivate_batch = true) {
	set_active_effect(null);
	set_active_reaction(null);
	set_component_context(null);
	if (deactivate_batch) current_batch?.deactivate();
}
/**
* @returns {(skip?: boolean) => void}
*/
function increment_pending() {
	var effect = active_effect;
	var boundary = effect.b;
	var batch = current_batch;
	var blocking = !!boundary?.is_rendered();
	boundary?.update_pending_count(1, batch);
	batch.increment(blocking, effect);
	return () => {
		boundary?.update_pending_count(-1, batch);
		batch.decrement(blocking, effect);
	};
}
/**
* @template V
* @param {() => V} fn
* @returns {Derived<V>}
*/
/*#__NO_SIDE_EFFECTS__*/
function derived(fn) {
	var flags = 2 | DIRTY;
	if (active_effect !== null) active_effect.f |= EFFECT_PRESERVED;
	return {
		ctx: component_context,
		deps: null,
		effects: null,
		equals,
		f: flags,
		fn,
		reactions: null,
		rv: 0,
		v: UNINITIALIZED,
		wv: 0,
		parent: active_effect,
		ac: null
	};
}
var OBSOLETE = Symbol("obsolete");
/**
* @template V
* @param {() => V | Promise<V>} fn
* @param {string} [label]
* @param {string} [location] If provided, print a warning if the value is not read immediately after update
* @returns {Promise<Source<V>>}
*/
/*#__NO_SIDE_EFFECTS__*/
function async_derived(fn, label, location) {
	let parent = active_effect;
	if (parent === null) async_derived_orphan();
	var promise = void 0;
	var signal = source(UNINITIALIZED);
	var should_suspend = !active_reaction;
	/** @type {Set<ReturnType<typeof deferred<V>>>} */
	var deferreds = /* @__PURE__ */ new Set();
	async_effect(() => {
		var effect = active_effect;
		/** @type {ReturnType<typeof deferred<V>>} */
		var d = deferred();
		promise = d.promise;
		try {
			Promise.resolve(fn()).then(d.resolve, (e) => {
				if (e !== STALE_REACTION) d.reject(e);
			}).finally(unset_context);
		} catch (error) {
			d.reject(error);
			unset_context();
		}
		var batch = current_batch;
		if (should_suspend) {
			if ((effect.f & 32768) !== 0) var decrement_pending = increment_pending();
			if (parent.b?.is_rendered()) batch.async_deriveds.get(effect)?.reject(OBSOLETE);
			else for (const d of deferreds.values()) d.reject(OBSOLETE);
			deferreds.add(d);
			batch.async_deriveds.set(effect, d);
		}
		/**
		* @param {any} value
		* @param {unknown} error
		*/
		const handler = (value, error = void 0) => {
			decrement_pending?.();
			deferreds.delete(d);
			if (error === OBSOLETE) return;
			batch.activate();
			if (error) {
				signal.f |= ERROR_VALUE;
				internal_set(signal, error);
			} else {
				if ((signal.f & 8388608) !== 0) signal.f ^= ERROR_VALUE;
				internal_set(signal, value);
			}
			batch.deactivate();
		};
		d.promise.then(handler, (e) => handler(null, e || "unknown"));
	});
	teardown(() => {
		for (const d of deferreds) d.reject(OBSOLETE);
	});
	return new Promise((fulfil) => {
		/** @param {Promise<V>} p */
		function next(p) {
			function go() {
				if (p === promise) fulfil(signal);
				else next(promise);
			}
			p.then(go, go);
		}
		next(promise);
	});
}
/**
* @template V
* @param {() => V} fn
* @returns {Derived<V>}
*/
/*#__NO_SIDE_EFFECTS__*/
function user_derived(fn) {
	const d = /* @__PURE__ */ derived(fn);
	if (!async_mode_flag) push_reaction_value(d);
	return d;
}
/**
* @template V
* @param {() => V} fn
* @returns {Derived<V>}
*/
/*#__NO_SIDE_EFFECTS__*/
function derived_safe_equal(fn) {
	const signal = /* @__PURE__ */ derived(fn);
	signal.equals = safe_equals;
	return signal;
}
/**
* @param {Derived} derived
* @returns {void}
*/
function destroy_derived_effects(derived) {
	var effects = derived.effects;
	if (effects !== null) {
		derived.effects = null;
		for (var i = 0; i < effects.length; i += 1) destroy_effect(effects[i]);
	}
}
/**
* @template T
* @param {Derived} derived
* @returns {T}
*/
function execute_derived(derived) {
	var value;
	var prev_active_effect = active_effect;
	var parent = derived.parent;
	if (!is_destroying_effect && parent !== null && derived.v !== UNINITIALIZED && (parent.f & 24576) !== 0) {
		derived_inert();
		return derived.v;
	}
	set_active_effect(parent);
	try {
		destroy_derived_effects(derived);
		value = update_reaction(derived);
	} finally {
		set_active_effect(prev_active_effect);
	}
	return value;
}
/**
* @param {Derived} derived
* @returns {void}
*/
function update_derived(derived) {
	var value = execute_derived(derived);
	if (!derived.equals(value)) {
		derived.wv = increment_write_version();
		if (!current_batch?.is_fork || derived.deps === null) {
			if (current_batch !== null) {
				current_batch.capture(derived, value, true);
				previous_batch?.capture(derived, value, true);
			} else derived.v = value;
			if (derived.deps === null) {
				set_signal_status(derived, CLEAN);
				return;
			}
		}
	}
	if (is_destroying_effect) return;
	if (batch_values !== null) {
		if (effect_tracking() || current_batch?.is_fork) batch_values.set(derived, value);
	} else update_derived_status(derived);
}
/**
* @param {Derived} derived
*/
function freeze_derived_effects(derived) {
	if (derived.effects === null) return;
	for (const e of derived.effects) if (e.teardown || e.ac) {
		e.teardown?.();
		if (e.ac !== null) without_reactive_context(() => {
			/** @type {AbortController} */ e.ac.abort(STALE_REACTION);
			e.ac = null;
		});
		if (e.fn !== null) e.teardown = noop;
		remove_reactions(e, 0);
		destroy_effect_children(e);
	}
}
/**
* @param {Derived} derived
*/
function unfreeze_derived_effects(derived) {
	if (derived.effects === null) return;
	for (const e of derived.effects) if (e.teardown && e.fn !== null) update_effect(e);
}
// node_modules/svelte/src/internal/client/reactivity/batch.js
/** @import { Fork } from 'svelte' */
/** @import { Derived, Effect, Reaction, Source, Value } from '#client' */
/** @type {Batch | null} */
var first_batch = null;
/** @type {Batch | null} */
var last_batch = null;
/** @type {Batch | null} */
var current_batch = null;
/**
* This is needed to avoid overwriting inputs
* @type {Batch | null}
*/
var previous_batch = null;
/**
* When time travelling (i.e. working in one batch, while other batches
* still have ongoing work), we ignore the real values of affected
* signals in favour of their values within the batch
* @type {Map<Value, any> | null}
*/
var batch_values = null;
/** @type {Effect | null} */
var last_scheduled_effect = null;
var is_flushing_sync = false;
var is_processing = false;
/**
* During traversal, this is an array. Newly created effects are (if not immediately
* executed) pushed to this array, rather than going through the scheduling
* rigamarole that would cause another turn of the flush loop.
* @type {Effect[] | null}
*/
var collected_effects = null;
/**
* An array of effects that are marked during traversal as a result of a `set`
* (not `internal_set`) call. These will be added to the next batch and
* trigger another `batch.process()`
* @type {Effect[] | null}
* @deprecated when we get rid of legacy mode and stores, we can get rid of this
*/
var legacy_updates = null;
var flush_count = 0;
var uid = 1;
var Batch = class Batch {
	id = uid++;
	/** True as soon as `#process` was called */
	started = false;
	linked = true;
	/** @type {Batch | null} */
	prev = null;
	/** @type {Batch | null} */
	next = null;
	/** @type {Map<Effect, ReturnType<typeof deferred<any>>>} */
	async_deriveds = /* @__PURE__ */ new Map();
	/**
	* The current values of any signals that are updated in this batch.
	* Tuple format: [value, is_derived] (note: is_derived is false for deriveds, too, if they were overridden via assignment)
	* The keys of this map are identical to `this.previous`
	* @type {Map<Value, [any, boolean]>}
	*/
	current = /* @__PURE__ */ new Map();
	/**
	* The values of any signals (sources and deriveds) that are updated in this batch _before_ those updates took place.
	* The keys of this map are identical to `this.current`
	* @type {Map<Value, any>}
	*/
	previous = /* @__PURE__ */ new Map();
	/**
	* When the batch is committed (and the DOM is updated), we need to remove old branches
	* and append new ones by calling the functions added inside (if/each/key/etc) blocks
	* @type {Set<(batch: Batch) => void>}
	*/
	#commit_callbacks = /* @__PURE__ */ new Set();
	/**
	* If a fork is discarded, we need to destroy any effects that are no longer needed
	* @type {Set<(batch: Batch) => void>}
	*/
	#discard_callbacks = /* @__PURE__ */ new Set();
	/**
	* The number of async effects that are currently in flight
	*/
	#pending = 0;
	/**
	* Async effects that are currently in flight, _not_ inside a pending boundary
	* @type {Map<Effect, number>}
	*/
	#blocking_pending = /* @__PURE__ */ new Map();
	/**
	* A deferred that resolves when the batch is committed, used with `settled()`
	* TODO replace with Promise.withResolvers once supported widely enough
	* @type {{ promise: Promise<void>, resolve: (value?: any) => void, reject: (reason: unknown) => void } | null}
	*/
	#deferred = null;
	/**
	* Effects that were scheduled in this batch but not yet 'resolved' into the
	* root effects that need to be flushed. Resolving — the upwards traversal that
	* marks the path to each effect on the shared effect tree (see #resolve) — is
	* deferred until the batch is processed, so that the markers are created and
	* consumed within a single traversal. Scheduling into other batches (which can
	* happen concurrently, e.g. while a batch is committed) can therefore never
	* observe (and be confused by) this batch's markers.
	* May contain duplicates — deduplication happens during resolving
	* @type {Effect[]}
	*/
	#scheduled = [];
	/**
	* Effects created while this batch was active.
	* @type {Effect[]}
	*/
	#new_effects = [];
	/**
	* Deferred effects (which run after async work has completed) and their status (DIRTY or MAYBE_DIRTY)
	* @type {Map<Effect, number>}
	*/
	#dirty_reactions = /* @__PURE__ */ new Map();
	/**
	* A map of branches that still exist, but will be destroyed when this batch
	* is committed — we skip over these during `process`.
	* The value contains child effects that were dirty/maybe_dirty before being reset,
	* so they can be rescheduled if the branch survives.
	* @type {Map<Effect, { d: Effect[], m: Effect[] }>}
	*/
	#skipped_branches = /* @__PURE__ */ new Map();
	/**
	* Inverse of #skipped_branches which we need to tell prior batches to unskip them when committing
	* @type {Set<Effect>}
	*/
	#unskipped_branches = /* @__PURE__ */ new Set();
	is_fork = false;
	#decrement_queued = false;
	constructor() {
		if (last_batch === null) first_batch = last_batch = this;
		else {
			last_batch.next = this;
			this.prev = last_batch;
		}
		last_batch = this;
	}
	#is_deferred() {
		if (this.is_fork) return true;
		for (const effect of this.#blocking_pending.keys()) if (!this.#is_skipped(effect)) return true;
		return false;
	}
	/**
	* Whether `effect` is inside a branch that this batch skips
	* @param {Effect} effect
	*/
	#is_skipped(effect) {
		for (var e = effect; e !== null; e = e.parent) if (this.#skipped_branches.has(e)) return true;
		return false;
	}
	/**
	* Add an effect to the #skipped_branches map and reset its children
	* @param {Effect} effect
	*/
	skip_effect(effect) {
		if (!this.#skipped_branches.has(effect)) this.#skipped_branches.set(effect, {
			d: [],
			m: []
		});
		this.#unskipped_branches.delete(effect);
	}
	/**
	* Remove an effect from the #skipped_branches map and reschedule
	* any tracked dirty/maybe_dirty child effects
	* @param {Effect} effect
	* @param {(e: Effect) => void} callback
	*/
	unskip_effect(effect, callback = (e) => this.schedule(e)) {
		var tracked = this.#skipped_branches.get(effect);
		if (tracked) {
			this.#skipped_branches.delete(effect);
			for (var e of tracked.d) {
				set_signal_status(e, DIRTY);
				callback(e);
			}
			for (e of tracked.m) {
				set_signal_status(e, MAYBE_DIRTY);
				callback(e);
			}
		}
		this.#unskipped_branches.add(effect);
	}
	/**
	* Convert the effects that were scheduled in this batch into the root effects
	* that need to be traversed, marking the path to each effect (by clearing the
	* `CLEAN` flag on ancestor branches) so that the traversal can find them.
	* This happens right before traversal rather than at scheduling time, so that
	* the markers left on the (shared) effect tree are created and consumed within
	* a single traversal — scheduling into other batches can never observe them
	* @returns {Effect[]}
	*/
	#resolve() {
		/** @type {Effect[]} */
		var roots = [];
		for (const effect of this.#scheduled) {
			if ((effect.f & 16384) !== 0 || (effect.f & 6144) === 0) continue;
			var e = effect;
			var covered = false;
			while (e.parent !== null) {
				e = e.parent;
				var flags = e.f;
				if ((flags & 96) !== 0) {
					if ((flags & 1024) === 0) {
						covered = true;
						break;
					}
					e.f ^= CLEAN;
				}
			}
			if (!covered) roots.push(e);
		}
		this.#scheduled = [];
		return roots;
	}
	#process() {
		this.started = true;
		for (const [e, status] of this.#dirty_reactions) {
			set_signal_status(e, status);
			this.schedule(e);
		}
		this.apply();
		/** @type {Effect[]} */
		var effects = collected_effects = [];
		/** @type {Effect[]} */
		var render_effects = [];
		/**
		* @type {Effect[]}
		* @deprecated when we get rid of legacy mode and stores, we can get rid of this
		*/
		var updates = legacy_updates = [];
		while (this.#scheduled.length > 0) {
			if (flush_count++ > 1e3) {
				this.#unlink();
				infinite_loop_guard();
			}
			for (const root of this.#resolve()) try {
				this.#traverse(root, effects, render_effects);
			} catch (e) {
				reset_all(root);
				if (!this.#is_deferred()) this.discard();
				throw e;
			}
		}
		current_batch = null;
		if (updates.length > 0) {
			var batch = Batch.ensure();
			for (const e of updates) batch.schedule(e);
		}
		collected_effects = null;
		legacy_updates = null;
		if (this.#is_deferred()) {
			this.#defer_effects(render_effects);
			this.#defer_effects(effects);
			for (const [e, t] of this.#skipped_branches) reset_branch(e, t);
			if (updates.length > 0)
 /** @type {Batch} */ current_batch.#process();
			return;
		}
		const earlier_batch = this.#find_earlier_batch();
		if (earlier_batch) {
			this.#defer_effects(render_effects);
			this.#defer_effects(effects);
			earlier_batch.#merge(this);
			return;
		}
		this.#dirty_reactions.clear();
		for (const fn of this.#commit_callbacks) fn(this);
		this.#commit_callbacks.clear();
		previous_batch = this;
		flush_queued_effects(render_effects);
		flush_queued_effects(effects);
		previous_batch = null;
		this.#deferred?.resolve();
		var next_batch = current_batch;
		if (this.#pending === 0 && (this.#scheduled.length === 0 || next_batch !== null)) {
			this.#unlink();
			if (async_mode_flag) {
				this.#commit();
				current_batch = next_batch;
			}
		}
		if (next_batch !== null) {
			old_values.clear();
			next_batch.#process();
		}
	}
	/**
	* Traverse the effect tree, executing effects or stashing
	* them for later execution as appropriate
	* @param {Effect} root
	* @param {Effect[]} effects
	* @param {Effect[]} render_effects
	*/
	#traverse(root, effects, render_effects) {
		root.f ^= CLEAN;
		var effect = root.first;
		while (effect !== null) {
			var flags = effect.f;
			var is_branch = (flags & 96) !== 0;
			if (!(is_branch && (flags & 1024) !== 0 || (flags & 8192) !== 0 || this.#skipped_branches.has(effect)) && effect.fn !== null) {
				if (is_branch) effect.f ^= CLEAN;
				else if ((flags & 4) !== 0) effects.push(effect);
				else if (async_mode_flag && (flags & 16777224) !== 0) render_effects.push(effect);
				else if (is_dirty(effect)) {
					if ((flags & 16) !== 0) this.add_dirty_reaction(effect, MAYBE_DIRTY);
					update_effect(effect);
				}
				var child = effect.first;
				if (child !== null) {
					effect = child;
					continue;
				}
			}
			while (effect !== null) {
				var next = effect.next;
				if (next !== null) {
					effect = next;
					break;
				}
				effect = effect.parent;
			}
		}
	}
	#find_earlier_batch() {
		for (var batch = this.prev; batch !== null; batch = batch.prev) if (!batch.is_fork && this.#intersects(batch)) return batch;
		return null;
	}
	/** @param {Batch} batch */
	#intersects(batch) {
		for (const [source, [, is_derived]] of this.current) {
			if (is_derived) continue;
			if (batch.current.has(source)) return true;
		}
		return false;
	}
	/**
	* @param {Batch} batch
	*/
	#merge(batch) {
		for (const [source, value] of batch.current) {
			if (!this.previous.has(source) && batch.previous.has(source)) this.previous.set(source, batch.previous.get(source));
			this.current.set(source, value);
		}
		for (const [effect, deferred] of batch.async_deriveds) {
			const d = this.async_deriveds.get(effect);
			if (d) deferred.promise.then(d.resolve).catch(d.reject);
		}
		batch.async_deriveds.clear();
		this.transfer_reactions(batch.#dirty_reactions);
		/**
		* mark all effects that depend on `batch.current`, except the
		* async effects that we just resolved (TODO unless they depend
		* on values in this batch that are NOT in the later batch?).
		* Through this we also will populate the correct #skipped_branches,
		* oncommit callbacks etc, so we don't need to merge them separately.
		* @param {Value} value
		*/
		const mark = (value) => {
			var reactions = value.reactions;
			if (reactions === null) return;
			if ((value.f & 2) !== 0 && (value.f & 6144) === 0) return;
			for (const reaction of reactions) {
				var flags = reaction.f;
				if ((flags & 2) !== 0) mark(reaction);
				else {
					var effect = reaction;
					if (flags & 4194320 && !this.async_deriveds.has(effect)) {
						this.#dirty_reactions.delete(effect);
						set_signal_status(effect, DIRTY);
						this.schedule(effect);
					}
				}
			}
		};
		for (const source of this.current.keys()) mark(source);
		this.oncommit(() => batch.discard());
		batch.#unlink();
		current_batch = this;
		this.#process();
	}
	/**
	* @param {Effect[]} effects
	*/
	#defer_effects(effects) {
		for (var i = 0; i < effects.length; i += 1) defer_effect(effects[i], this.#dirty_reactions);
	}
	/**
	* Associate a change to a given source with the current
	* batch, noting its previous and current values
	* @param {Value} source
	* @param {any} value
	* @param {boolean} [is_derived]
	*/
	capture(source, value, is_derived = false) {
		if (source.v !== UNINITIALIZED && !this.previous.has(source)) this.previous.set(source, source.v);
		if ((source.f & 8388608) === 0) {
			this.current.set(source, [value, is_derived]);
			batch_values?.set(source, value);
		}
		if (!this.is_fork) source.v = value;
	}
	activate() {
		current_batch = this;
	}
	deactivate() {
		current_batch = null;
		batch_values = null;
	}
	flush() {
		try {
			is_processing = true;
			current_batch = this;
			this.#process();
		} finally {
			flush_count = 0;
			last_scheduled_effect = null;
			collected_effects = null;
			legacy_updates = null;
			is_processing = false;
			current_batch = null;
			batch_values = null;
			old_values.clear();
		}
	}
	discard() {
		for (const fn of this.#discard_callbacks) fn(this);
		this.#discard_callbacks.clear();
		for (const deferred of this.async_deriveds.values()) deferred.reject(OBSOLETE);
		this.#unlink();
		this.#deferred?.resolve();
	}
	/**
	* @param {Effect} effect
	*/
	register_created_effect(effect) {
		this.#new_effects.push(effect);
	}
	#commit() {
		for (let batch = first_batch; batch !== null; batch = batch.next) {
			var is_earlier = batch.id < this.id;
			/** @type {Source[]} */
			var sources = [];
			for (const [source, [value, is_derived]] of this.current) {
				if (batch.current.has(source)) {
					var batch_value = batch.current.get(source)[0];
					if (is_earlier && value !== batch_value) batch.current.set(source, [value, is_derived]);
					else continue;
				}
				sources.push(source);
			}
			if (is_earlier) for (const [effect, deferred] of this.async_deriveds) {
				const d = batch.async_deriveds.get(effect);
				if (d) deferred.promise.then(d.resolve).catch(d.reject);
			}
			var current = [...batch.current.keys()].filter((source) => !batch.current.get(source)[1]);
			if (!batch.started || current.length === 0) continue;
			var others = current.filter((source) => !this.current.has(source));
			if (others.length === 0) {
				if (is_earlier) batch.discard();
			} else if (sources.length > 0) {
				if (is_earlier) for (const unskipped of this.#unskipped_branches) batch.unskip_effect(unskipped, (e) => {
					if ((e.f & 4194320) !== 0) batch.schedule(e);
					else batch.#defer_effects([e]);
				});
				batch.activate();
				/** @type {Set<Value>} */
				var marked = /* @__PURE__ */ new Set();
				/** @type {Map<Reaction, boolean>} */
				var checked = /* @__PURE__ */ new Map();
				for (var source of sources) mark_effects(source, others, marked, checked);
				checked = /* @__PURE__ */ new Map();
				var current_unequal = [...batch.current].filter(([c, v1]) => {
					const v2 = this.current.get(c);
					if (!v2) return true;
					return v2[0] !== v1[0] || v2[1] !== v1[1];
				}).map(([c]) => c);
				if (current_unequal.length > 0) {
					for (const effect of this.#new_effects) if ((effect.f & 155648) === 0 && depends_on(effect, current_unequal, checked)) {
						if ((effect.f & 4194320) !== 0) {
							set_signal_status(effect, DIRTY);
							batch.schedule(effect);
						} else batch.add_dirty_reaction(effect, DIRTY);
					}
				}
				if (batch.#scheduled.length > 0 && !batch.#decrement_queued) {
					batch.apply();
					for (var root of batch.#resolve()) batch.#traverse(root, [], []);
				}
				batch.deactivate();
			}
		}
	}
	/**
	* @param {boolean} blocking
	* @param {Effect} effect
	*/
	increment(blocking, effect) {
		this.#pending += 1;
		if (blocking) {
			let blocking_pending_count = this.#blocking_pending.get(effect) ?? 0;
			this.#blocking_pending.set(effect, blocking_pending_count + 1);
		}
	}
	/**
	* @param {boolean} blocking
	* @param {Effect} effect
	*/
	decrement(blocking, effect) {
		this.#pending -= 1;
		if (blocking) {
			let blocking_pending_count = this.#blocking_pending.get(effect) ?? 0;
			if (blocking_pending_count === 1) this.#blocking_pending.delete(effect);
			else this.#blocking_pending.set(effect, blocking_pending_count - 1);
		}
		if (this.#decrement_queued) return;
		this.#decrement_queued = true;
		queue_micro_task(() => {
			this.#decrement_queued = false;
			if (this.linked) this.flush();
		});
	}
	/**
	* @param {Map<Effect, number>} dirty_reactions
	*/
	transfer_reactions(dirty_reactions) {
		for (const [effect, status] of dirty_reactions) this.add_dirty_reaction(effect, status);
		dirty_reactions.clear();
	}
	/**
	* @param {Effect} effect
	* @param {number} status
	*/
	add_dirty_reaction(effect, status) {
		if (status === 2048 || this.#dirty_reactions.get(effect) !== 2048) this.#dirty_reactions.set(effect, status);
	}
	/** @param {(batch: Batch) => void} fn */
	oncommit(fn) {
		this.#commit_callbacks.add(fn);
	}
	/** @param {(batch: Batch) => void} fn */
	ondiscard(fn) {
		this.#discard_callbacks.add(fn);
	}
	settled() {
		return (this.#deferred ??= deferred()).promise;
	}
	static ensure() {
		if (current_batch === null) {
			const batch = current_batch = new Batch();
			if (!is_processing && !is_flushing_sync) queue_micro_task(() => {
				if (!batch.started) batch.flush();
			});
		}
		return current_batch;
	}
	apply() {
		if (!async_mode_flag || !this.is_fork && this.prev === null && this.next === null) {
			batch_values = null;
			return;
		}
		batch_values = /* @__PURE__ */ new Map();
		for (const [source, [value]] of this.current) batch_values.set(source, value);
		for (let batch = first_batch; batch !== null; batch = batch.next) {
			if (batch === this || batch.is_fork) continue;
			if (batch.id >= this.id || !batch.#intersects(this)) {
				for (const [source, previous] of batch.previous) if (!batch_values.has(source)) batch_values.set(source, previous);
			}
		}
	}
	/**
	*
	* @param {Effect} effect
	*/
	schedule(effect) {
		last_scheduled_effect = effect;
		if (effect.b?.is_pending && (effect.f & 16777228) !== 0 && (effect.f & 32768) === 0) {
			effect.b.defer_effect(effect);
			return;
		}
		this.#scheduled.push(effect);
	}
	#unlink() {
		if (!this.linked) return;
		var prev = this.prev;
		var next = this.next;
		if (prev === null) first_batch = next;
		else prev.next = next;
		if (next === null) last_batch = prev;
		else next.prev = prev;
		this.linked = false;
	}
};
/**
* Synchronously flush any pending updates.
* Returns void if no callback is provided, otherwise returns the result of calling the callback.
* @template [T=void]
* @param {(() => T) | undefined} [fn]
* @returns {T}
*/
function flushSync(fn) {
	var was_flushing_sync = is_flushing_sync;
	var prev_previous_batch = previous_batch;
	previous_batch = null;
	is_flushing_sync = true;
	try {
		var result;
		if (fn) {
			flushSync();
			result = fn();
		}
		while (true) {
			flush_tasks();
			if (current_batch === null) return result;
			current_batch.flush();
		}
	} finally {
		is_flushing_sync = was_flushing_sync;
		previous_batch = prev_previous_batch;
	}
}
function infinite_loop_guard() {
	try {
		effect_update_depth_exceeded();
	} catch (error) {
		invoke_error_boundary(error, last_scheduled_effect);
	}
}
/** @type {Set<Effect> | null} */
var eager_block_effects = null;
/**
* @param {Array<Effect>} effects
* @returns {void}
*/
function flush_queued_effects(effects) {
	var length = effects.length;
	if (length === 0) return;
	var i = 0;
	while (i < length) {
		var effect = effects[i++];
		if ((effect.f & 24576) === 0 && is_dirty(effect)) {
			eager_block_effects = /* @__PURE__ */ new Set();
			update_effect(effect);
			if (effect.deps === null && effect.first === null && effect.nodes === null && effect.teardown === null && effect.ac === null) unlink_effect(effect);
			if (eager_block_effects?.size > 0) {
				old_values.clear();
				for (const e of eager_block_effects) {
					if ((e.f & 24576) !== 0) continue;
					/** @type {Effect[]} */
					const ordered_effects = [e];
					let ancestor = e.parent;
					while (ancestor !== null) {
						if (eager_block_effects.has(ancestor)) {
							eager_block_effects.delete(ancestor);
							ordered_effects.push(ancestor);
						}
						ancestor = ancestor.parent;
					}
					for (let j = ordered_effects.length - 1; j >= 0; j--) {
						const e = ordered_effects[j];
						if ((e.f & 24576) !== 0) continue;
						update_effect(e);
					}
				}
				eager_block_effects.clear();
			}
		}
	}
	eager_block_effects = null;
}
/**
* This is similar to `mark_reactions`, but it only marks async/block effects
* depending on `value` and at least one of the other `sources`, so that
* these effects can re-run after another batch has been committed
* @param {Value} value
* @param {Source[]} sources
* @param {Set<Value>} marked
* @param {Map<Reaction, boolean>} checked
*/
function mark_effects(value, sources, marked, checked) {
	if (marked.has(value)) return;
	marked.add(value);
	if (value.reactions !== null) for (const reaction of value.reactions) {
		const flags = reaction.f;
		if ((flags & 2) !== 0) mark_effects(reaction, sources, marked, checked);
		else if ((flags & 4194320) !== 0 && (flags & 2048) === 0 && depends_on(reaction, sources, checked)) {
			set_signal_status(reaction, DIRTY);
			schedule_effect(reaction);
		}
	}
}
/**
* @param {Reaction} reaction
* @param {Source[]} sources
* @param {Map<Reaction, boolean>} checked
*/
function depends_on(reaction, sources, checked) {
	const depends = checked.get(reaction);
	if (depends !== void 0) return depends;
	if (reaction.deps !== null) for (const dep of reaction.deps) {
		if (includes.call(sources, dep)) return true;
		if ((dep.f & 2) !== 0 && depends_on(dep, sources, checked)) {
			checked.set(dep, true);
			return true;
		}
	}
	checked.set(reaction, false);
	return false;
}
/**
* @param {Effect} effect
* @returns {void}
*/
function schedule_effect(effect) {
	/** @type {Batch} */ current_batch.schedule(effect);
}
/**
* Mark all the effects inside a skipped branch CLEAN, so that
* they can be correctly rescheduled later. Tracks dirty and maybe_dirty
* effects so they can be rescheduled if the branch survives.
* @param {Effect} effect
* @param {{ d: Effect[], m: Effect[] }} tracked
*/
function reset_branch(effect, tracked) {
	if ((effect.f & 32) !== 0 && (effect.f & 1024) !== 0) return;
	if ((effect.f & 2048) !== 0) tracked.d.push(effect);
	else if ((effect.f & 4096) !== 0) tracked.m.push(effect);
	set_signal_status(effect, CLEAN);
	var e = effect.first;
	while (e !== null) {
		reset_branch(e, tracked);
		e = e.next;
	}
}
/**
* Mark an entire effect tree clean following an error
* @param {Effect} effect
*/
function reset_all(effect) {
	set_signal_status(effect, CLEAN);
	var e = effect.first;
	while (e !== null) {
		reset_all(e);
		e = e.next;
	}
}
// node_modules/svelte/src/internal/client/reactivity/sources.js
/** @import { Derived, Effect, Source, Value } from '#client' */
/** @type {Set<Effect>} */
var eager_effects = /* @__PURE__ */ new Set();
/** @type {Map<Value, any>} */
var old_values = /* @__PURE__ */ new Map();
var eager_effects_deferred = false;
/**
* @template V
* @param {V} v
* @param {Error | null} [stack]
* @returns {Source<V>}
*/
function source(v, stack) {
	return {
		f: 0,
		v,
		reactions: null,
		equals,
		rv: 0,
		wv: 0
	};
}
/**
* @template V
* @param {V} v
* @param {Error | null} [stack]
*/
/*#__NO_SIDE_EFFECTS__*/
function state(v, stack) {
	const s = source(v, stack);
	push_reaction_value(s);
	return s;
}
/**
* @template V
* @param {V} initial_value
* @param {boolean} [immutable]
* @returns {Source<V>}
*/
/*#__NO_SIDE_EFFECTS__*/
function mutable_source(initial_value, immutable = false, trackable = true) {
	const s = source(initial_value);
	if (!immutable) s.equals = safe_equals;
	if (legacy_mode_flag && trackable && component_context !== null && component_context.l !== null) (component_context.l.s ??= []).push(s);
	return s;
}
/**
* @template V
* @param {Value<V>} source
* @param {V} value
* @param {boolean} [should_proxy]
* @returns {V}
*/
function set(source, value, should_proxy = false) {
	if (active_reaction !== null && (!untracking || (active_reaction.f & 131072) !== 0) && is_runes() && (active_reaction.f & 4325394) !== 0 && (current_sources === null || !current_sources.has(source))) state_unsafe_mutation();
	return internal_set(source, should_proxy ? proxy(value) : value, legacy_updates);
}
/**
* A set of signals we have already seen while traversing in mark_reactions.
* Not always set to balance the common case of sources only having a couple
* of (transitive) dependencies (where always creating a Set would be bad for perf)
* with the edge case of extremely deep or wide dependency arrays with cycles.
* @type {Set<any> | null}
*/
var seen = null;
/** Number of transitive dependencies, see {@link seen} for more info */
var count_deps = 0;
/**
* @template V
* @param {Value<V>} source
* @param {V} value
* @param {Effect[] | null} [updated_during_traversal]
* @returns {V}
*/
function internal_set(source, value, updated_during_traversal = null) {
	if (!source.equals(value)) {
		if (is_destroying_effect) old_values.set(source, value);
		else if (!old_values.has(source)) old_values.set(source, source.v);
		var batch = Batch.ensure();
		batch.capture(source, value);
		if ((source.f & 2) !== 0) {
			const derived = source;
			if ((source.f & 2048) !== 0) execute_derived(derived);
			if (batch_values === null) update_derived_status(derived);
		}
		source.wv = increment_write_version();
		seen = null;
		count_deps = 0;
		mark_reactions(source, DIRTY, updated_during_traversal);
		seen = null;
		if (is_runes() && active_effect !== null && (active_effect.f & 1024) !== 0 && (active_effect.f & 96) === 0) {
			if (untracked_writes === null) set_untracked_writes([source]);
			else untracked_writes.push(source);
		}
		if (!batch.is_fork && eager_effects.size > 0 && !eager_effects_deferred) flush_eager_effects();
	}
	return value;
}
function flush_eager_effects() {
	eager_effects_deferred = false;
	for (const effect of eager_effects) {
		if ((effect.f & 1024) !== 0) set_signal_status(effect, MAYBE_DIRTY);
		let dirty;
		try {
			dirty = is_dirty(effect);
		} catch {
			dirty = true;
		}
		if (dirty) update_effect(effect);
	}
	eager_effects.clear();
}
/**
* Silently (without using `get`) increment a source
* @param {Source<number>} source
*/
function increment(source) {
	set(source, source.v + 1);
}
/**
* @param {Value} signal
* @param {number} status should be DIRTY or MAYBE_DIRTY
* @param {Effect[] | null} updated_during_traversal
* @returns {void}
*/
function mark_reactions(signal, status, updated_during_traversal) {
	var reactions = signal.reactions;
	if (reactions === null) return;
	var runes = is_runes();
	var length = reactions.length;
	count_deps += length;
	if (count_deps > 1e5 && seen === null) seen = /* @__PURE__ */ new Set();
	if (seen !== null) {
		if (seen.has(signal)) return;
		seen.add(signal);
	}
	for (var i = 0; i < length; i++) {
		var reaction = reactions[i];
		var flags = reaction.f;
		if (!runes && reaction === active_effect) continue;
		var not_dirty = (flags & DIRTY) === 0;
		if (not_dirty) set_signal_status(reaction, status);
		if ((flags & 131072) !== 0) eager_effects.add(reaction);
		else if ((flags & 2) !== 0) {
			var derived = reaction;
			batch_values?.delete(derived);
			mark_reactions(derived, MAYBE_DIRTY, updated_during_traversal);
		} else if (not_dirty) {
			var effect = reaction;
			if ((flags & 16) !== 0 && eager_block_effects !== null) eager_block_effects.add(effect);
			if (updated_during_traversal !== null) updated_during_traversal.push(effect);
			else schedule_effect(effect);
		}
	}
}
/**
* @template T
* @param {T} value
* @returns {T}
*/
function proxy(value) {
	if (typeof value !== "object" || value === null || STATE_SYMBOL in value || COMPONENT_SYMBOL in value) return value;
	const prototype = get_prototype_of(value);
	if (prototype !== object_prototype && prototype !== array_prototype) return value;
	/** @type {Map<any, Source<any>>} */
	var sources = /* @__PURE__ */ new Map();
	var is_proxied_array = is_array(value);
	var version = /* @__PURE__ */ state(0);
	var stack = null;
	var parent_version = update_version;
	/**
	* Executes the proxy in the context of the reaction it was originally created in, if any
	* @template T
	* @param {() => T} fn
	*/
	var with_parent = (fn) => {
		if (update_version === parent_version) return fn();
		var reaction = active_reaction;
		var version = update_version;
		set_active_reaction(null);
		set_update_version(parent_version);
		var result = fn();
		set_active_reaction(reaction);
		set_update_version(version);
		return result;
	};
	if (is_proxied_array) sources.set("length", /* @__PURE__ */ state(
		/** @type {any[]} */
		value.length,
		stack
	));
	return new Proxy(value, {
		defineProperty(_, prop, descriptor) {
			if (!("value" in descriptor) || descriptor.configurable === false || descriptor.enumerable === false || descriptor.writable === false) state_descriptors_fixed();
			var s = sources.get(prop);
			if (s === void 0) with_parent(() => {
				var s = /* @__PURE__ */ state(descriptor.value, stack);
				sources.set(prop, s);
				return s;
			});
			else set(s, descriptor.value, true);
			return true;
		},
		deleteProperty(target, prop) {
			var s = sources.get(prop);
			if (s === void 0) {
				if (prop in target) {
					const s = with_parent(() => /* @__PURE__ */ state(UNINITIALIZED, stack));
					sources.set(prop, s);
					increment(version);
				}
			} else {
				set(s, UNINITIALIZED);
				increment(version);
			}
			return true;
		},
		get(target, prop, receiver) {
			if (prop === STATE_SYMBOL) return value;
			var s = sources.get(prop);
			var exists = prop in target;
			if (s === void 0 && (!exists || get_descriptor(target, prop)?.writable)) {
				s = with_parent(() => {
					return /* @__PURE__ */ state(proxy(exists ? target[prop] : UNINITIALIZED), stack);
				});
				sources.set(prop, s);
			}
			if (s !== void 0) {
				var v = get(s);
				return v === UNINITIALIZED ? void 0 : v;
			}
			return Reflect.get(target, prop, receiver);
		},
		getOwnPropertyDescriptor(target, prop) {
			this.has?.(target, prop);
			var descriptor = Reflect.getOwnPropertyDescriptor(target, prop);
			var s = sources.get(prop);
			if (s !== void 0) {
				var value = get(s);
				if (value === UNINITIALIZED) return;
				if (descriptor && "value" in descriptor) descriptor.value = value;
				else return {
					enumerable: true,
					configurable: true,
					value,
					writable: true
				};
			}
			return descriptor;
		},
		has(target, prop) {
			if (prop === STATE_SYMBOL) return true;
			var s = sources.get(prop);
			var has = s !== void 0 && s.v !== UNINITIALIZED || Reflect.has(target, prop);
			if (s !== void 0 || (active_effect !== null || active_reaction !== null) && (!has || get_descriptor(target, prop)?.writable)) {
				if (s === void 0) {
					s = with_parent(() => {
						return /* @__PURE__ */ state(has ? proxy(target[prop]) : UNINITIALIZED, stack);
					});
					sources.set(prop, s);
				}
				if (get(s) === UNINITIALIZED) return false;
			}
			return has;
		},
		set(target, prop, value, receiver) {
			var s = sources.get(prop);
			var has = prop in target;
			if (is_proxied_array && prop === "length") for (var i = value; i < s.v; i += 1) {
				var other_s = sources.get(i + "");
				if (other_s !== void 0) set(other_s, UNINITIALIZED);
				else if (i in target) {
					other_s = with_parent(() => /* @__PURE__ */ state(UNINITIALIZED, stack));
					sources.set(i + "", other_s);
				}
			}
			if (s === void 0) {
				if (!has || get_descriptor(target, prop)?.writable) {
					s = with_parent(() => /* @__PURE__ */ state(void 0, stack));
					set(s, proxy(value));
					sources.set(prop, s);
				}
			} else {
				has = s.v !== UNINITIALIZED;
				var p = with_parent(() => proxy(value));
				set(s, p);
			}
			var descriptor = Reflect.getOwnPropertyDescriptor(target, prop);
			if (descriptor?.set) descriptor.set.call(receiver, value);
			if (!has) {
				if (is_proxied_array && typeof prop === "string") {
					var ls = sources.get("length");
					var n = Number(prop);
					if (Number.isInteger(n) && n >= ls.v) set(ls, n + 1);
				}
				increment(version);
			}
			return true;
		},
		ownKeys(target) {
			get(version);
			var own_keys = Reflect.ownKeys(target).filter((key) => {
				var source = sources.get(key);
				return source === void 0 || source.v !== UNINITIALIZED;
			});
			for (var [key, source] of sources) if (source.v !== UNINITIALIZED && !(key in target)) own_keys.push(key);
			return own_keys;
		},
		setPrototypeOf() {
			state_prototype_fixed();
		}
	});
}
// node_modules/svelte/src/internal/client/dom/operations.js
/** @import { Effect, TemplateNode } from '#client' */
/** @type {Window} */
var $window;
/** @type {boolean} */
var is_firefox;
/** @type {() => Node | null} */
var first_child_getter;
/** @type {() => Node | null} */
var next_sibling_getter;
/**
* Initialize these lazily to avoid issues when using the runtime in a server context
* where these globals are not available while avoiding a separate server entry point
*/
function init_operations() {
	if ($window !== void 0) return;
	$window = window;
	is_firefox = /Firefox/.test(navigator.userAgent);
	var element_prototype = Element.prototype;
	var node_prototype = Node.prototype;
	var text_prototype = Text.prototype;
	first_child_getter = get_descriptor(node_prototype, "firstChild").get;
	next_sibling_getter = get_descriptor(node_prototype, "nextSibling").get;
	if (is_extensible(element_prototype)) {
		/** @type {any} */ element_prototype[CLASS_CACHE] = void 0;
		/** @type {any} */ element_prototype[ATTRIBUTES_CACHE] = null;
		/** @type {any} */ element_prototype[STYLE_CACHE] = void 0;
		element_prototype.__e = void 0;
	}
	if (is_extensible(text_prototype))
 /** @type {any} */ text_prototype[TEXT_CACHE] = void 0;
}
/**
* @param {string} value
* @returns {Text}
*/
function create_text(value = "") {
	return document.createTextNode(value);
}
/**
* @template {Node} N
* @param {N} node
*/
/*@__NO_SIDE_EFFECTS__*/
function get_first_child(node) {
	return first_child_getter.call(node);
}
/**
* @template {Node} N
* @param {N} node
*/
/*@__NO_SIDE_EFFECTS__*/
function get_next_sibling(node) {
	return next_sibling_getter.call(node);
}
/**
* Don't mark this as side-effect-free, hydration needs to walk all nodes
* @template {Node} N
* @param {N} node
* @param {boolean} is_text
* @returns {TemplateNode | null}
*/
function child(node, is_text) {
	if (!hydrating) return /* @__PURE__ */ get_first_child(node);
	var child = /* @__PURE__ */ get_first_child(hydrate_node);
	if (child === null) child = hydrate_node.appendChild(create_text());
	else if (is_text && child.nodeType !== 3) {
		var text = create_text();
		child?.before(text);
		set_hydrate_node(text);
		return text;
	}
	if (is_text) merge_text_nodes(child);
	set_hydrate_node(child);
	return child;
}
/**
* Don't mark this as side-effect-free, hydration needs to walk all nodes
* @param {TemplateNode} node
* @param {boolean} [is_text]
* @returns {TemplateNode | null}
*/
function first_child(node, is_text = false) {
	if (!hydrating) {
		var first = /* @__PURE__ */ get_first_child(node);
		if (first instanceof Comment && first.data === "") return /* @__PURE__ */ get_next_sibling(first);
		return first;
	}
	if (is_text) {
		if (hydrate_node?.nodeType !== 3) {
			var text = create_text();
			hydrate_node?.before(text);
			set_hydrate_node(text);
			return text;
		}
		merge_text_nodes(hydrate_node);
	}
	return hydrate_node;
}
/**
* `child`, for the very common case of an element with exactly one child. Resetting the
* hydration cursor is part of the same step, so the compiler doesn't have to emit a
* separate `reset` call for every `<p>{text}</p>` in an app.
* Don't mark this as side-effect-free, hydration needs to walk all nodes
* @param {TemplateNode} node
* @param {boolean} [is_text]
* @returns {TemplateNode | null}
*/
function only_child(node, is_text = false) {
	if (!hydrating) return /* @__PURE__ */ get_first_child(node);
	var first = child(node, is_text);
	reset(node);
	return first;
}
/**
* Don't mark this as side-effect-free, hydration needs to walk all nodes
* @param {TemplateNode} node
* @param {number} count
* @param {boolean} is_text
* @returns {TemplateNode | null}
*/
function sibling(node, count = 1, is_text = false) {
	let next_sibling = hydrating ? hydrate_node : node;
	var last_sibling;
	while (count--) {
		last_sibling = next_sibling;
		next_sibling = /* @__PURE__ */ get_next_sibling(next_sibling);
	}
	if (!hydrating) return next_sibling;
	if (is_text) {
		if (next_sibling?.nodeType !== 3) {
			var text = create_text();
			if (next_sibling === null) last_sibling?.after(text);
			else next_sibling.before(text);
			set_hydrate_node(text);
			return text;
		}
		merge_text_nodes(next_sibling);
	}
	set_hydrate_node(next_sibling);
	return next_sibling;
}
/**
* @template {Node} N
* @param {N} node
* @returns {void}
*/
function clear_text_content(node) {
	node.textContent = "";
}
/**
* Returns `true` if we're updating the current block, for example `condition` in
* an `{#if condition}` block just changed. In this case, the branch should be
* appended (or removed) at the same time as other updates within the
* current `<svelte:boundary>`
*/
function should_defer_append() {
	if (!async_mode_flag) return false;
	if (eager_block_effects !== null) return false;
	return (active_effect.f & REACTION_RAN) !== 0;
}
/**
* Branching here is intentional and load-bearing for perf. `createElement(tag)`
* hits a fast path in Blink that `createElementNS(NAMESPACE_HTML, tag)` doesn't,
* and passing an explicit `undefined` as the trailing options arg measurably
* slows both APIs. Funnelling every case through a single `createElementNS(ns,
* tag, options)` call would be smaller but slower on the HTML path.
*
* @template {keyof HTMLElementTagNameMap | string} T
* @param {T} tag
* @param {string} [namespace]
* @param {string} [is]
* @returns {T extends keyof HTMLElementTagNameMap ? HTMLElementTagNameMap[T] : Element}
*/
function create_element(tag, namespace, is) {
	if (namespace == null || namespace === "http://www.w3.org/1999/xhtml") return is ? document.createElement(tag, { is }) : document.createElement(tag);
	return is ? document.createElementNS(namespace, tag, { is }) : document.createElementNS(namespace, tag);
}
/**
* Browsers split text nodes larger than 65536 bytes when parsing.
* For hydration to succeed, we need to stitch them back together
* @param {Text} text
*/
function merge_text_nodes(text) {
	if (text.nodeValue.length < 65536) return;
	let next = text.nextSibling;
	while (next !== null && next.nodeType === 3) {
		next.remove();
		/** @type {string} */ text.nodeValue += next.nodeValue;
		next = text.nextSibling;
	}
}
/**
* @param {unknown} error
*/
function handle_error(error) {
	var effect = active_effect;
	if (effect === null) {
		/** @type {Derived} */ active_reaction.f |= ERROR_VALUE;
		return error;
	}
	if ((effect.f & 32768) === 0 && (effect.f & 4) === 0) throw error;
	invoke_error_boundary(error, effect);
}
/**
* @param {unknown} error
* @param {Effect | null} effect
*/
function invoke_error_boundary(error, effect) {
	if (error === HYDRATION_ERROR) throw error;
	if (effect !== null && (effect.f & 16384) !== 0) return;
	while (effect !== null) {
		if ((effect.f & 128) !== 0 && (effect.f & 33570816) === 0) {
			if ((effect.f & 32768) === 0) throw error;
			try {
				/** @type {Boundary} */ effect.b.error(error);
				return;
			} catch (e) {
				error = e;
			}
		}
		effect = effect.parent;
	}
	throw error;
}
// node_modules/svelte/src/internal/client/reactivity/effects.js
/** @import { Blocker, ComponentContext, ComponentContextLegacy, Derived, Effect, TemplateNode, TransitionManager } from '#client' */
/**
* @param {'$effect' | '$effect.pre' | '$inspect'} rune
*/
function validate_effect(rune) {
	if (active_effect === null) {
		if (active_reaction === null) effect_orphan(rune);
		effect_in_unowned_derived();
	}
	if (is_destroying_effect) effect_in_teardown(rune);
}
/**
* @param {Effect} effect
* @param {Effect} parent_effect
*/
function push_effect(effect, parent_effect) {
	var parent_last = parent_effect.last;
	if (parent_last === null) parent_effect.last = parent_effect.first = effect;
	else {
		parent_last.next = effect;
		effect.prev = parent_last;
		parent_effect.last = effect;
	}
}
/**
* @param {number} type
* @param {null | (() => void | (() => void))} fn
* @returns {Effect}
*/
function create_effect(type, fn) {
	var parent = active_effect;
	if (parent !== null && (parent.f & 8192) !== 0) type |= INERT;
	/** @type {Effect} */
	var effect = {
		ctx: component_context,
		deps: null,
		nodes: null,
		f: type | DIRTY | 512,
		first: null,
		fn,
		last: null,
		next: null,
		parent,
		b: parent && parent.b,
		prev: null,
		teardown: null,
		wv: 0,
		ac: null
	};
	current_batch?.register_created_effect(effect);
	/** @type {Effect | null} */
	var e = effect;
	if ((type & 4) !== 0) {
		if (collected_effects !== null) collected_effects.push(effect);
		else Batch.ensure().schedule(effect);
	} else if (fn !== null) {
		try {
			update_effect(effect);
		} catch (e) {
			destroy_effect(effect);
			throw e;
		}
		if (e.deps === null && e.teardown === null && e.nodes === null && e.first === e.last && (e.f & 524288) === 0) {
			e = e.first;
			if ((type & 16) !== 0 && (type & 65536) !== 0 && e !== null) e.f |= EFFECT_TRANSPARENT;
		}
	}
	if (e !== null) {
		e.parent = parent;
		if (parent !== null) push_effect(e, parent);
		if (active_reaction !== null && (active_reaction.f & 2) !== 0 && (type & 64) === 0) {
			var derived = active_reaction;
			(derived.effects ??= []).push(e);
		}
	}
	return effect;
}
/**
* Internal representation of `$effect.tracking()`
* @returns {boolean}
*/
function effect_tracking() {
	return active_reaction !== null && !untracking;
}
/**
* @param {() => void} fn
*/
function teardown(fn) {
	const effect = create_effect(8, null);
	set_signal_status(effect, CLEAN);
	effect.teardown = fn;
	return effect;
}
/**
* Internal representation of `$effect(...)`
* @param {() => void | (() => void)} fn
*/
function user_effect(fn) {
	validate_effect("$effect");
	var flags = active_effect.f;
	if (!active_reaction && (flags & 32) !== 0 && component_context !== null && !component_context.i) {
		var context = component_context;
		(context.e ??= []).push(fn);
	} else return create_user_effect(fn);
}
/**
* @param {() => void | (() => void)} fn
*/
function create_user_effect(fn) {
	return create_effect(4 | USER_EFFECT, fn);
}
/**
* An effect root whose children can transition out
* @param {() => void} fn
* @returns {(options?: { outro?: boolean }) => Promise<void>}
*/
function component_root(fn) {
	Batch.ensure();
	const effect = create_effect(64 | EFFECT_PRESERVED, fn);
	return (options = {}) => {
		return new Promise((fulfil) => {
			if (options.outro) pause_effect(effect, () => {
				destroy_effect(effect);
				fulfil(void 0);
			});
			else {
				destroy_effect(effect);
				fulfil(void 0);
			}
		});
	};
}
/**
* @param {() => void | (() => void)} fn
* @returns {Effect}
*/
function effect(fn) {
	return create_effect(4, fn);
}
/**
* @param {() => void | (() => void)} fn
* @returns {Effect}
*/
function async_effect(fn) {
	return create_effect(ASYNC | EFFECT_PRESERVED, fn);
}
/**
* @param {() => void | (() => void)} fn
* @returns {Effect}
*/
function render_effect(fn, flags = 0) {
	return create_effect(8 | flags, fn);
}
/**
* @param {(...expressions: any) => void | (() => void)} fn
* @param {Array<() => any>} sync
* @param {Array<() => Promise<any>>} async
* @param {Blocker[]} blockers
*/
function template_effect(fn, sync = [], async = [], blockers = []) {
	flatten(blockers, sync, async, (values) => {
		create_effect(8, () => {
			fn(...values.map(get));
		});
	});
}
/**
* @param {(() => void)} fn
* @param {number} flags
*/
function block(fn, flags = 0) {
	return create_effect(16 | flags, fn);
}
/**
* @param {(() => void)} fn
*/
function branch(fn) {
	return create_effect(32 | EFFECT_PRESERVED, fn);
}
/**
* @param {Effect} effect
*/
function execute_effect_teardown(effect) {
	var teardown = effect.teardown;
	if (teardown !== null) {
		const previously_destroying_effect = is_destroying_effect;
		const previous_reaction = active_reaction;
		set_is_destroying_effect(true);
		set_active_reaction(null);
		try {
			teardown.call(null);
		} catch (error) {
			invoke_error_boundary(error, effect.parent);
		} finally {
			set_is_destroying_effect(previously_destroying_effect);
			set_active_reaction(previous_reaction);
		}
	}
}
/**
* @param {Effect} signal
* @param {boolean} remove_dom
* @returns {void}
*/
function destroy_effect_children(signal, remove_dom = false) {
	var effect = signal.first;
	signal.first = signal.last = null;
	while (effect !== null) {
		const controller = effect.ac;
		if (controller !== null) without_reactive_context(() => {
			controller.abort(STALE_REACTION);
		});
		var next = effect.next;
		if ((effect.f & 64) !== 0) effect.parent = null;
		else destroy_effect(effect, remove_dom);
		effect = next;
	}
}
/**
* @param {Effect} signal
* @returns {void}
*/
function destroy_block_effect_children(signal) {
	var effect = signal.first;
	while (effect !== null) {
		var next = effect.next;
		if ((effect.f & 32) === 0) destroy_effect(effect);
		effect = next;
	}
}
/**
* @param {Effect} effect
* @param {boolean} [remove_dom]
* @returns {void}
*/
function destroy_effect(effect, remove_dom = true) {
	var removed = false;
	if ((remove_dom || (effect.f & 262144) !== 0) && effect.nodes !== null && effect.nodes.end !== null) {
		remove_effect_dom(effect.nodes.start, effect.nodes.end);
		removed = true;
	}
	effect.f |= DESTROYING;
	destroy_effect_children(effect, remove_dom && !removed);
	remove_reactions(effect, 0);
	var transitions = effect.nodes && effect.nodes.t;
	if (transitions !== null) for (const transition of transitions) transition.stop();
	execute_effect_teardown(effect);
	effect.f ^= DESTROYING;
	effect.f |= DESTROYED;
	var parent = effect.parent;
	if (parent !== null && parent.first !== null) unlink_effect(effect);
	effect.next = effect.prev = effect.teardown = effect.ctx = effect.deps = effect.fn = effect.nodes = effect.ac = effect.b = null;
}
/**
*
* @param {TemplateNode | null} node
* @param {TemplateNode} end
*/
function remove_effect_dom(node, end) {
	while (node !== null) {
		/** @type {TemplateNode | null} */
		var next = node === end ? null : /* @__PURE__ */ get_next_sibling(node);
		node.remove();
		node = next;
	}
}
/**
* Detach an effect from the effect tree, freeing up memory and
* reducing the amount of work that happens on subsequent traversals
* @param {Effect} effect
*/
function unlink_effect(effect) {
	var parent = effect.parent;
	var prev = effect.prev;
	var next = effect.next;
	if (prev !== null) prev.next = next;
	if (next !== null) next.prev = prev;
	if (parent !== null) {
		if (parent.first === effect) parent.first = next;
		if (parent.last === effect) parent.last = prev;
	}
}
/**
* When a block effect is removed, we don't immediately destroy it or yank it
* out of the DOM, because it might have transitions. Instead, we 'pause' it.
* It stays around (in memory, and in the DOM) until outro transitions have
* completed, and if the state change is reversed then we _resume_ it.
* A paused effect does not update, and the DOM subtree becomes inert.
* @param {Effect} effect
* @param {() => void} [callback]
* @param {boolean} [destroy]
*/
function pause_effect(effect, callback, destroy = true) {
	/** @type {TransitionManager[]} */
	var transitions = [];
	effect.f |= 256;
	pause_children(effect, transitions, true);
	var fn = () => {
		if (destroy) destroy_effect(effect);
		if (callback) callback();
	};
	var remaining = transitions.length;
	if (remaining > 0) {
		var check = () => --remaining || fn();
		for (var transition of transitions) transition.out(check);
	} else fn();
}
/**
* @param {Effect} effect
* @param {TransitionManager[]} transitions
* @param {boolean} local
*/
function pause_children(effect, transitions, local) {
	if ((effect.f & 8192) !== 0) return;
	effect.f ^= INERT;
	var t = effect.nodes && effect.nodes.t;
	if (t !== null) {
		for (const transition of t) if (transition.is_global || local) transitions.push(transition);
	}
	var child = effect.first;
	while (child !== null) {
		var sibling = child.next;
		if ((child.f & 64) === 0) {
			var transparent = (child.f & 65536) !== 0 || (child.f & 32) !== 0 && (effect.f & 16) !== 0;
			pause_children(child, transitions, transparent ? local : false);
		}
		child = sibling;
	}
}
/**
* The opposite of `pause_effect`. We call this if (for example)
* `x` becomes falsy then truthy: `{#if x}...{/if}`
* @param {Effect} effect
*/
function resume_effect(effect) {
	effect.f &= -257;
	resume_children(effect, true);
}
/**
* @param {Effect} effect
* @param {boolean} local
*/
function resume_children(effect, local) {
	if ((effect.f & 256) !== 0) return;
	if ((effect.f & 8192) === 0) return;
	effect.f ^= INERT;
	if ((effect.f & 1024) === 0) {
		set_signal_status(effect, DIRTY);
		Batch.ensure().schedule(effect);
	}
	var child = effect.first;
	while (child !== null) {
		var sibling = child.next;
		var transparent = (child.f & 65536) !== 0 || (child.f & 32) !== 0;
		resume_children(child, transparent ? local : false);
		child = sibling;
	}
	var t = effect.nodes && effect.nodes.t;
	if (t !== null) {
		for (const transition of t) if (transition.is_global || local) transition.in();
	}
}
/**
* @param {Effect} effect
* @param {DocumentFragment} fragment
*/
function move_effect(effect, fragment) {
	if (!effect.nodes) return;
	/** @type {TemplateNode | null} */
	var node = effect.nodes.start;
	var end = effect.nodes.end;
	while (node !== null) {
		/** @type {TemplateNode | null} */
		var next = node === end ? null : /* @__PURE__ */ get_next_sibling(node);
		fragment.append(node);
		node = next;
	}
}
// node_modules/svelte/src/internal/client/legacy.js
/**
* @type {Set<Value> | null}
* @deprecated
*/
var captured_signals = null;
// node_modules/svelte/src/internal/client/runtime.js
/** @import { Derived, Effect, Reaction, Source, Value } from '#client' */
var is_destroying_effect = false;
/** @param {boolean} value */
function set_is_destroying_effect(value) {
	is_destroying_effect = value;
}
/** @type {null | Reaction} */
var active_reaction = null;
var untracking = false;
/** @param {null | Reaction} reaction */
function set_active_reaction(reaction) {
	active_reaction = reaction;
}
/** @type {null | Effect} */
var active_effect = null;
/** @param {null | Effect} effect */
function set_active_effect(effect) {
	active_effect = effect;
}
/**
* When sources are created within a reaction, reading and writing
* them within that reaction should not cause a re-run
* @type {null | Set<Value>}
*/
var current_sources = null;
/** @param {Value} value */
function push_reaction_value(value) {
	if (active_reaction !== null && (!async_mode_flag && (active_reaction.f & 2097152) !== 0 || (active_reaction.f & 2) !== 0)) (current_sources ??= /* @__PURE__ */ new Set()).add(value);
}
/**
* The dependencies of the reaction that is currently being executed. In many cases,
* the dependencies are unchanged between runs, and so this will be `null` unless
* and until a new dependency is accessed — we track this via `skipped_deps`
* @type {null | Value[]}
*/
var new_deps = null;
var skipped_deps = 0;
/**
* Tracks writes that the effect it's executed in doesn't listen to yet,
* so that the dependency can be added to the effect later on if it then reads it
* @type {null | Value[]}
*/
var untracked_writes = null;
/** @param {null | Value[]} value */
function set_untracked_writes(value) {
	untracked_writes = value;
}
/**
* @type {number} Used by sources and deriveds for handling updates.
* Version starts from 1 so that unowned deriveds differentiate between a created effect and a run one for tracing
**/
var write_version = 1;
/** @type {number} Used to version each read of a source of derived to avoid duplicating dependencies inside a reaction */
var read_version = 0;
var update_version = read_version;
/** @param {number} value */
function set_update_version(value) {
	update_version = value;
}
function increment_write_version() {
	return ++write_version;
}
/**
* Determines whether a derived or effect is dirty.
* If it is MAYBE_DIRTY, will set the status to CLEAN
* @param {Reaction} reaction
* @returns {boolean}
*/
function is_dirty(reaction) {
	var flags = reaction.f;
	if ((flags & 2048) !== 0) return true;
	if ((flags & 4096) !== 0) {
		var dependencies = reaction.deps;
		var length = dependencies.length;
		for (var i = 0; i < length; i++) {
			var dependency = dependencies[i];
			if (is_dirty(dependency)) update_derived(dependency);
			if (dependency.wv > reaction.wv) return true;
		}
		if ((flags & 512) !== 0 && batch_values === null) set_signal_status(reaction, CLEAN);
	}
	return false;
}
/**
* @param {Value} signal
* @param {Effect} effect
* @param {boolean} [root]
*/
function schedule_possible_effect_self_invalidation(signal, effect, root = true) {
	var reactions = signal.reactions;
	if (reactions === null) return;
	if (!async_mode_flag && current_sources !== null && current_sources.has(signal)) return;
	for (var i = 0; i < reactions.length; i++) {
		var reaction = reactions[i];
		if ((reaction.f & 2) !== 0) schedule_possible_effect_self_invalidation(reaction, effect, false);
		else if (effect === reaction) {
			if (root) set_signal_status(reaction, DIRTY);
			else if ((reaction.f & 1024) !== 0) set_signal_status(reaction, MAYBE_DIRTY);
			schedule_effect(reaction);
		}
	}
}
/** @param {Reaction} reaction */
function update_reaction(reaction) {
	var previous_deps = new_deps;
	var previous_skipped_deps = skipped_deps;
	var previous_untracked_writes = untracked_writes;
	var previous_reaction = active_reaction;
	var previous_sources = current_sources;
	var previous_component_context = component_context;
	var previous_untracking = untracking;
	var previous_update_version = update_version;
	var flags = reaction.f;
	new_deps = null;
	skipped_deps = 0;
	untracked_writes = null;
	active_reaction = (flags & 96) === 0 ? reaction : null;
	current_sources = null;
	set_component_context(reaction.ctx);
	untracking = false;
	update_version = ++read_version;
	if (reaction.ac !== null) {
		without_reactive_context(() => {
			/** @type {AbortController} */ reaction.ac.abort(STALE_REACTION);
		});
		reaction.ac = null;
	}
	try {
		reaction.f |= REACTION_IS_UPDATING;
		var fn = reaction.fn;
		var result = fn();
		reaction.f |= REACTION_RAN;
		var deps = update_dependencies(reaction);
		if (is_runes() && untracked_writes !== null && !untracking && deps !== null && (reaction.f & 6146) === 0) for (var i = 0; i < untracked_writes.length; i++) schedule_possible_effect_self_invalidation(untracked_writes[i], reaction);
		if (previous_reaction !== null && previous_reaction !== reaction) {
			read_version++;
			if (previous_reaction.deps !== null) for (let i = 0; i < previous_skipped_deps; i += 1) previous_reaction.deps[i].rv = read_version;
			if (previous_deps !== null) for (const dep of previous_deps) dep.rv = read_version;
			if (untracked_writes !== null) {
				if (previous_untracked_writes === null) previous_untracked_writes = untracked_writes;
				else previous_untracked_writes.push(...untracked_writes);
			}
		}
		if ((reaction.f & 8388608) !== 0) reaction.f ^= ERROR_VALUE;
		return result;
	} catch (error) {
		update_dependencies(reaction);
		return handle_error(error);
	} finally {
		reaction.f ^= REACTION_IS_UPDATING;
		new_deps = previous_deps;
		skipped_deps = previous_skipped_deps;
		untracked_writes = previous_untracked_writes;
		active_reaction = previous_reaction;
		current_sources = previous_sources;
		set_component_context(previous_component_context);
		untracking = previous_untracking;
		update_version = previous_update_version;
	}
}
/**
* @param {Reaction} reaction
*/
function update_dependencies(reaction) {
	var deps = reaction.deps;
	var is_fork = current_batch?.is_fork;
	if (new_deps !== null) {
		var i;
		if (!is_fork) remove_reactions(reaction, skipped_deps);
		if (deps !== null && skipped_deps > 0) {
			deps.length = skipped_deps + new_deps.length;
			for (i = 0; i < new_deps.length; i++) deps[skipped_deps + i] = new_deps[i];
		} else reaction.deps = deps = new_deps;
		if (effect_tracking() && (reaction.f & 512) !== 0) for (i = skipped_deps; i < deps.length; i++) (deps[i].reactions ??= []).push(reaction);
	} else if (!is_fork && deps !== null && skipped_deps < deps.length) {
		remove_reactions(reaction, skipped_deps);
		deps.length = skipped_deps;
	}
	return deps;
}
/**
* @template V
* @param {Reaction} signal
* @param {Value<V>} dependency
* @returns {void}
*/
function remove_reaction(signal, dependency) {
	let reactions = dependency.reactions;
	if (reactions !== null) {
		var index = index_of.call(reactions, signal);
		if (index !== -1) {
			var new_length = reactions.length - 1;
			if (new_length === 0) reactions = dependency.reactions = null;
			else {
				reactions[index] = reactions[new_length];
				reactions.pop();
			}
		}
	}
	if (reactions === null && (dependency.f & 2) !== 0 && (new_deps === null || !includes.call(new_deps, dependency))) {
		var derived = dependency;
		if ((derived.f & 512) !== 0) derived.f ^= 512;
		if (derived.v !== UNINITIALIZED) update_derived_status(derived);
		if (derived.ac !== null) without_reactive_context(() => {
			/** @type {AbortController} */ derived.ac.abort(STALE_REACTION);
			derived.ac = null;
			set_signal_status(derived, DIRTY);
		});
		freeze_derived_effects(derived);
		remove_reactions(derived, 0);
	}
}
/**
* @param {Reaction} signal
* @param {number} start_index
* @returns {void}
*/
function remove_reactions(signal, start_index) {
	var dependencies = signal.deps;
	if (dependencies === null) return;
	for (var i = start_index; i < dependencies.length; i++) remove_reaction(signal, dependencies[i]);
}
/**
* @param {Effect} effect
* @returns {void}
*/
function update_effect(effect) {
	var flags = effect.f;
	if ((flags & 16384) !== 0) return;
	set_signal_status(effect, CLEAN);
	var previous_effect = active_effect;
	active_effect = effect;
	try {
		if ((flags & 16777232) !== 0) destroy_block_effect_children(effect);
		else destroy_effect_children(effect);
		execute_effect_teardown(effect);
		var teardown = update_reaction(effect);
		effect.teardown = typeof teardown === "function" ? teardown : null;
		effect.wv = write_version;
	} finally {
		active_effect = previous_effect;
	}
}
/**
* Returns a promise that resolves once any pending state changes have been applied.
* @returns {Promise<void>}
*/
async function tick() {
	if (async_mode_flag) return new Promise((f) => {
		requestAnimationFrame(() => f());
		setTimeout(() => f());
	});
	await Promise.resolve();
	flushSync();
}
/**
* @template V
* @param {Value<V>} signal
* @returns {V}
*/
function get(signal) {
	var is_derived = (signal.f & 2) !== 0;
	captured_signals?.add(signal);
	if (active_reaction !== null && !untracking) {
		if (!(active_effect !== null && (active_effect.f & 16384) !== 0) && (current_sources === null || !current_sources.has(signal))) {
			var deps = active_reaction.deps;
			if ((active_reaction.f & 2097152) !== 0) {
				if (signal.rv < read_version) {
					signal.rv = read_version;
					if (new_deps === null && deps !== null && deps[skipped_deps] === signal) skipped_deps++;
					else if (new_deps === null) new_deps = [signal];
					else new_deps.push(signal);
				}
			} else {
				active_reaction.deps ??= [];
				if (!includes.call(active_reaction.deps, signal)) active_reaction.deps.push(signal);
				var reactions = signal.reactions;
				if (reactions === null) signal.reactions = [active_reaction];
				else if (!includes.call(reactions, active_reaction)) reactions.push(active_reaction);
			}
		}
	}
	if (is_destroying_effect && old_values.has(signal)) return old_values.get(signal);
	if (is_derived) {
		var derived = signal;
		if (is_destroying_effect) {
			var value = derived.v;
			if ((derived.f & 1024) === 0 && derived.reactions !== null || depends_on_old_values(derived)) value = execute_derived(derived);
			old_values.set(derived, value);
			return value;
		}
		var should_connect = (derived.f & 512) === 0 && !untracking && active_reaction !== null && (active_reaction.f & 512) !== 0;
		var is_new = (derived.f & REACTION_RAN) === 0;
		if (is_dirty(derived)) {
			if (should_connect) derived.f |= 512;
			update_derived(derived);
		}
		if (should_connect && !is_new) {
			unfreeze_derived_effects(derived);
			reconnect(derived);
		}
	}
	if (batch_values?.has(signal)) return batch_values.get(signal);
	if ((signal.f & 8388608) !== 0) throw signal.v;
	return signal.v;
}
/**
* (Re)connect a disconnected derived, so that it is notified
* of changes in `mark_reactions`
* @param {Derived} derived
*/
function reconnect(derived) {
	derived.f |= 512;
	if (derived.deps === null) return;
	for (const dep of derived.deps) {
		var reactions = dep.reactions;
		if (reactions === null) dep.reactions = [derived];
		else if (!includes.call(reactions, derived)) reactions.push(derived);
		if ((dep.f & 2) !== 0 && (dep.f & 512) === 0) {
			unfreeze_derived_effects(dep);
			reconnect(dep);
		}
	}
}
/** @param {Derived} derived */
function depends_on_old_values(derived) {
	if (derived.v === UNINITIALIZED) return true;
	if (derived.deps === null) return false;
	for (const dep of derived.deps) {
		if (old_values.has(dep)) return true;
		if ((dep.f & 2) !== 0 && depends_on_old_values(dep)) return true;
	}
	return false;
}
/**
* When used inside a [`$derived`](https://svelte.dev/docs/svelte/$derived) or [`$effect`](https://svelte.dev/docs/svelte/$effect),
* any state read inside `fn` will not be treated as a dependency.
*
* ```ts
* $effect(() => {
*   // this will run when `data` changes, but not when `time` changes
*   save(data, {
*     timestamp: untrack(() => time)
*   });
* });
* ```
* @template T
* @param {() => T} fn
* @returns {T}
*/
function untrack(fn) {
	var previous_untracking = untracking;
	try {
		untracking = true;
		return fn();
	} finally {
		untracking = previous_untracking;
	}
}
// node_modules/svelte/src/internal/client/dom/elements/events.js
/**
* Used on elements, as a map of event type -> event handler,
* and on events themselves to track which element handled an event
*/
var event_symbol = Symbol("events");
/** @type {Set<string>} */
var all_registered_events = /* @__PURE__ */ new Set();
/** @type {Set<(events: Array<string>) => void>} */
var root_event_handles = /* @__PURE__ */ new Set();
/**
* @param {string} event_name
* @param {EventTarget} dom
* @param {EventListener} [handler]
* @param {AddEventListenerOptions} [options]
*/
function create_event(event_name, dom, handler, options = {}) {
	/**
	* @this {EventTarget}
	*/
	function target_handler(event) {
		if (!options.capture) handle_event_propagation.call(dom, event);
		if (!event.cancelBubble) return without_reactive_context(() => {
			return handler?.call(this, event);
		});
	}
	if (event_name.startsWith("pointer") || event_name.startsWith("touch") || event_name === "wheel") {
		target_handler.__removed = false;
		queue_micro_task(() => {
			if (!target_handler.__removed) dom.addEventListener(event_name, target_handler, options);
		});
	} else dom.addEventListener(event_name, target_handler, options);
	return target_handler;
}
/**
* @param {string} event_name
* @param {Element} dom
* @param {EventListener} [handler]
* @param {boolean} [capture]
* @param {boolean} [passive]
* @returns {void}
*/
function event(event_name, dom, handler, capture, passive) {
	var options = {
		capture,
		passive
	};
	var target_handler = create_event(event_name, dom, handler, options);
	if (dom === document.body || dom === window || dom === document || dom instanceof HTMLMediaElement) teardown(() => {
		target_handler.__removed = true;
		dom.removeEventListener(event_name, target_handler, options);
	});
}
/**
* @param {string} event_name
* @param {Element} element
* @param {EventListener} [handler]
* @returns {void}
*/
function delegated(event_name, element, handler) {
	(element[event_symbol] ??= {})[event_name] = handler;
}
/**
* @param {Array<string>} events
* @returns {void}
*/
function delegate(events) {
	for (var i = 0; i < events.length; i++) all_registered_events.add(events[i]);
	for (var fn of root_event_handles) fn(events);
}
var last_propagated_event = null;
var last_propagated_event_clear_scheduled = false;
/**
* @this {EventTarget}
* @param {Event} event
* @returns {void}
*/
function handle_event_propagation(event) {
	var handler_element = this;
	var owner_document = handler_element.ownerDocument;
	var event_name = event.type;
	var path = event.composedPath?.() || [];
	var current_target = path[0] || event.target;
	last_propagated_event = event;
	if (!last_propagated_event_clear_scheduled) {
		last_propagated_event_clear_scheduled = true;
		setTimeout(() => {
			last_propagated_event_clear_scheduled = false;
			last_propagated_event = null;
		});
	}
	var path_idx = 0;
	var handled_at = last_propagated_event === event && event[event_symbol];
	if (handled_at) {
		var at_idx = path.indexOf(handled_at);
		if (at_idx !== -1 && (handler_element === document || handler_element === window)) {
			event[event_symbol] = handler_element;
			return;
		}
		var handler_idx = path.indexOf(handler_element);
		if (handler_idx === -1) return;
		if (at_idx <= handler_idx) path_idx = at_idx;
	}
	current_target = path[path_idx] || event.target;
	if (current_target === handler_element) return;
	define_property(event, "currentTarget", {
		configurable: true,
		get() {
			return current_target || owner_document;
		}
	});
	var previous_reaction = active_reaction;
	var previous_effect = active_effect;
	set_active_reaction(null);
	set_active_effect(null);
	try {
		/**
		* @type {unknown}
		*/
		var throw_error;
		/**
		* @type {unknown[]}
		*/
		var other_errors = [];
		while (current_target !== null) {
			if (current_target === handler_element) break;
			try {
				var delegated = current_target[event_symbol]?.[event_name];
				if (delegated != null && (!current_target.disabled || event.target === current_target)) delegated.call(current_target, event);
			} catch (error) {
				if (throw_error) other_errors.push(error);
				else throw_error = error;
			}
			if (event.cancelBubble) break;
			path_idx++;
			current_target = path_idx < path.length ? path[path_idx] : null;
		}
		if (throw_error) {
			for (let error of other_errors) queueMicrotask(() => {
				throw error;
			});
			throw throw_error;
		}
	} finally {
		event[event_symbol] = handler_element;
		delete event.currentTarget;
		set_active_reaction(previous_reaction);
		set_active_effect(previous_effect);
	}
}
// node_modules/svelte/src/internal/client/dom/reconciler.js
var policy = globalThis?.window?.trustedTypes && /* @__PURE__ */ globalThis.window.trustedTypes.createPolicy("svelte-trusted-html", { 
/** @param {string} html */
createHTML: (html) => {
	return html;
} });
/** @param {string} html */
function create_trusted_html(html) {
	return policy?.createHTML(html) ?? html;
}
/**
* @param {string} html
*/
function create_fragment_from_html(html) {
	var elem = create_element("template");
	elem.innerHTML = create_trusted_html(html.replaceAll("<!>", "<!---->"));
	return elem.content;
}
// node_modules/svelte/src/internal/client/dom/template.js
/** @import { Effect, EffectNodes, TemplateNode } from '#client' */
/** @import { TemplateStructure } from './types' */
/**
* @param {TemplateNode} start
* @param {TemplateNode | null} end
*/
function assign_nodes(start, end) {
	var effect = active_effect;
	if (effect.nodes === null) effect.nodes = {
		start,
		end,
		a: null,
		t: null
	};
}
/**
* @param {string} content
* @param {number} flags
* @returns {() => Node | Node[]}
*/
/*#__NO_SIDE_EFFECTS__*/
function from_html(content, flags) {
	var is_fragment = (flags & 1) !== 0;
	var use_import_node = (flags & 2) !== 0;
	/** @type {Node} */
	var node;
	/**
	* Whether or not the first item is a text/element node. If not, we need to
	* create an additional comment node to act as `effect.nodes.start`
	*/
	var has_start = !content.startsWith("<!>");
	return () => {
		if (hydrating) {
			assign_nodes(hydrate_node, null);
			return hydrate_node;
		}
		if (node === void 0) {
			node = create_fragment_from_html(has_start ? content : "<!>" + content);
			if (!is_fragment) node = /* @__PURE__ */ get_first_child(node);
		}
		var clone = use_import_node || is_firefox ? document.importNode(node, true) : node.cloneNode(true);
		if (is_fragment) {
			var start = /* @__PURE__ */ get_first_child(clone);
			var end = clone.lastChild;
			assign_nodes(start, end);
		} else assign_nodes(clone, clone);
		return clone;
	};
}
/**
* @param {string} content
* @param {number} flags
* @param {'svg' | 'math'} ns
* @returns {() => Node | Node[]}
*/
/*#__NO_SIDE_EFFECTS__*/
function from_namespace(content, flags, ns = "svg") {
	/**
	* Whether or not the first item is a text/element node. If not, we need to
	* create an additional comment node to act as `effect.nodes.start`
	*/
	var has_start = !content.startsWith("<!>");
	var is_fragment = (flags & 1) !== 0;
	var wrapped = `<${ns}>${has_start ? content : "<!>" + content}</${ns}>`;
	/** @type {Element | DocumentFragment} */
	var node;
	return () => {
		if (hydrating) {
			assign_nodes(hydrate_node, null);
			return hydrate_node;
		}
		if (!node) {
			var root = /* @__PURE__ */ get_first_child(create_fragment_from_html(wrapped));
			if (is_fragment) {
				node = document.createDocumentFragment();
				while (/* @__PURE__ */ get_first_child(root)) node.appendChild(/* @__PURE__ */ get_first_child(root));
			} else node = /* @__PURE__ */ get_first_child(root);
		}
		var clone = node.cloneNode(true);
		if (is_fragment) {
			var start = /* @__PURE__ */ get_first_child(clone);
			var end = clone.lastChild;
			assign_nodes(start, end);
		} else assign_nodes(clone, clone);
		return clone;
	};
}
/**
* @param {string} content
* @param {number} flags
*/
/*#__NO_SIDE_EFFECTS__*/
function from_svg(content, flags) {
	return /* @__PURE__ */ from_namespace(content, flags, "svg");
}
/**
* @returns {TemplateNode | DocumentFragment}
*/
function comment() {
	if (hydrating) {
		assign_nodes(hydrate_node, null);
		return hydrate_node;
	}
	var frag = document.createDocumentFragment();
	var start = document.createComment("");
	var anchor = create_text();
	frag.append(start, anchor);
	assign_nodes(start, anchor);
	return frag;
}
/**
* Assign the created (or in hydration mode, traversed) dom elements to the current block
* and insert the elements into the dom (in client mode).
* @param {Text | Comment | Element} anchor
* @param {DocumentFragment | Element} dom
*/
function append(anchor, dom) {
	if (hydrating) {
		var effect = active_effect;
		if ((effect.f & 32768) === 0 || effect.nodes.end === null) effect.nodes.end = hydrate_node;
		hydrate_next();
		return;
	}
	if (anchor === null) return;
	anchor.before(dom);
}
/**
* Subset of delegated events which should be passive by default.
* These two are already passive via browser defaults on window, document and body.
* But since
* - we're delegating them
* - they happen often
* - they apply to mobile which is generally less performant
* we're marking them as passive by default for other elements, too.
*/
var PASSIVE_EVENTS = ["touchstart", "touchmove"];
/**
* Returns `true` if `name` is a passive event
* @param {string} name
*/
function is_passive_event(name) {
	return PASSIVE_EVENTS.includes(name);
}
// node_modules/svelte/src/reactivity/create-subscriber.js
/**
* Returns a `subscribe` function that integrates external event-based systems with Svelte's reactivity.
* It's particularly useful for integrating with web APIs like `MediaQuery`, `IntersectionObserver`, or `WebSocket`.
*
* If `subscribe` is called inside an effect (including indirectly, for example inside a getter),
* the `start` callback will be called with an `update` function. Whenever `update` is called, the effect re-runs.
*
* If `start` returns a cleanup function, it will be called when the effect is destroyed.
*
* If `subscribe` is called in multiple effects, `start` will only be called once as long as the effects
* are active, and the returned teardown function will only be called when all effects are destroyed.
*
* It's best understood with an example. Here's an implementation of [`MediaQuery`](https://svelte.dev/docs/svelte/svelte-reactivity#MediaQuery):
*
* ```js
* import { createSubscriber } from 'svelte/reactivity';
* import { on } from 'svelte/events';
*
* export class MediaQuery {
* 	#query;
* 	#subscribe;
*
* 	constructor(query) {
* 		this.#query = window.matchMedia(`(${query})`);
*
* 		this.#subscribe = createSubscriber((update) => {
* 			// when the `change` event occurs, re-run any effects that read `this.current`
* 			const off = on(this.#query, 'change', update);
*
* 			// stop listening when all the effects are destroyed
* 			return () => off();
* 		});
* 	}
*
* 	get current() {
* 		// This makes the getter reactive, if read in an effect
* 		this.#subscribe();
*
* 		// Return the current state of the query, whether or not we're in an effect
* 		return this.#query.matches;
* 	}
* }
* ```
* @param {(update: () => void) => (() => void) | void} start
* @since 5.7.0
*/
function createSubscriber(start) {
	let subscribers = 0;
	let version = source(0);
	/** @type {(() => void) | void} */
	let stop;
	return () => {
		if (effect_tracking()) {
			get(version);
			render_effect(() => {
				if (subscribers === 0) stop = untrack(() => start(() => increment(version)));
				subscribers += 1;
				return () => {
					queue_micro_task(() => {
						subscribers -= 1;
						if (subscribers === 0) {
							stop?.();
							stop = void 0;
							increment(version);
						}
					});
				};
			});
		}
	};
}
// node_modules/svelte/src/internal/client/dom/blocks/boundary.js
/** @import { Effect, Source, TemplateNode, } from '#client' */
/**
* @typedef {{
* 	 onerror?: ((error: unknown, reset: () => void) => void) | null;
*   failed?: ((anchor: Node, error: () => unknown, reset: () => () => void) => void) | null;
*   pending?: ((anchor: Node) => void) | null;
* }} BoundaryProps
*/
var flags = EFFECT_TRANSPARENT | EFFECT_PRESERVED;
/**
* @param {TemplateNode} node
* @param {BoundaryProps} props
* @param {((anchor: Node) => void)} children
* @param {((error: unknown) => unknown) | undefined} [transform_error]
* @returns {void}
*/
function boundary(node, props, children, transform_error) {
	new Boundary(node, props, children, transform_error);
}
var Boundary = class {
	/** @type {Boundary | null} */
	parent;
	is_pending = false;
	/**
	* API-level transformError transform function. Transforms errors before they reach the `failed` snippet.
	* Inherited from parent boundary, or defaults to identity.
	* @type {(error: unknown) => unknown}
	*/
	transform_error;
	/** @type {TemplateNode} */
	#anchor;
	/** @type {TemplateNode | null} */
	#hydrate_open = hydrating ? hydrate_node : null;
	/** @type {BoundaryProps} */
	#props;
	/** @type {((anchor: Node) => void)} */
	#children;
	/** @type {Effect} */
	#effect;
	/** @type {Effect | null} */
	#main_effect = null;
	/** @type {Effect | null} */
	#pending_effect = null;
	/** @type {Effect | null} */
	#failed_effect = null;
	/** @type {DocumentFragment | null} */
	#offscreen_fragment = null;
	#local_pending_count = 0;
	#pending_count = 0;
	#pending_count_update_queued = false;
	/** @type {Map<Effect, number>} */
	#dirty_reactions = /* @__PURE__ */ new Map();
	/**
	* A source containing the number of pending async deriveds/expressions.
	* Only created if `$effect.pending()` is used inside the boundary,
	* otherwise updating the source results in needless `Batch.ensure()`
	* calls followed by no-op flushes
	* @type {Source<number> | null}
	*/
	#effect_pending = null;
	#effect_pending_subscriber = createSubscriber(() => {
		this.#effect_pending = source(this.#local_pending_count);
		return () => {
			this.#effect_pending = null;
		};
	});
	/**
	* @param {TemplateNode} node
	* @param {BoundaryProps} props
	* @param {((anchor: Node) => void)} children
	* @param {((error: unknown) => unknown) | undefined} [transform_error]
	*/
	constructor(node, props, children, transform_error) {
		this.#anchor = node;
		this.#props = props;
		this.#children = (anchor) => {
			var effect = active_effect;
			effect.b = this;
			effect.f |= 128;
			children(anchor);
		};
		this.parent = active_effect.b;
		this.transform_error = transform_error ?? this.parent?.transform_error ?? ((e) => e);
		this.#effect = block(() => {
			if (hydrating) {
				const comment_data = read_hydration_instruction(this.#hydrate_open);
				hydrate_next();
				const server_rendered_pending = comment_data === "[!";
				if (comment_data.startsWith("[?")) {
					const serialized_error = JSON.parse(comment_data.slice(2));
					this.#hydrate_failed_content(serialized_error);
				} else if (server_rendered_pending) this.#hydrate_pending_content();
				else this.#hydrate_resolved_content();
			} else this.#render();
		}, flags);
		if (hydrating) this.#anchor = hydrate_node;
	}
	#hydrate_resolved_content() {
		try {
			this.#main_effect = branch(() => this.#children(this.#anchor));
		} catch (error) {
			this.error(error);
		}
	}
	/**
	* @param {unknown} error The deserialized error from the server's hydration comment
	*/
	#hydrate_failed_content(error) {
		const failed = this.#props.failed;
		const { reset, invoke_onerror } = this.#create_reset(error);
		queue_micro_task(invoke_onerror);
		if (!failed) return;
		this.#failed_effect = branch(() => {
			failed(this.#anchor, () => error, () => reset);
		});
	}
	/**
	* Creates the `reset` function for a failed boundary, along with a function
	* that invokes `onerror` with it (if provided)
	* @param {unknown} error
	* @returns {{ reset: () => void, invoke_onerror: () => void }}
	*/
	#create_reset(error) {
		var did_reset = false;
		var calling_on_error = false;
		const reset = () => {
			if (this.#is_destroyed()) return;
			if (did_reset) {
				svelte_boundary_reset_noop();
				return;
			}
			did_reset = true;
			if (calling_on_error) svelte_boundary_reset_onerror();
			if (this.#failed_effect !== null) pause_effect(this.#failed_effect, () => {
				this.#failed_effect = null;
			});
			this.#run(() => {
				this.#render();
			});
		};
		const invoke_onerror = () => {
			if (this.#is_destroyed()) return;
			try {
				calling_on_error = true;
				this.#props.onerror?.(error, reset);
				calling_on_error = false;
			} catch (err) {
				invoke_error_boundary(err, this.#effect && this.#effect.parent);
			}
		};
		return {
			reset,
			invoke_onerror
		};
	}
	#is_destroyed() {
		return (this.#effect.f & (DESTROYED | DESTROYING)) !== 0;
	}
	#hydrate_pending_content() {
		const pending = this.#props.pending;
		if (!pending) return;
		this.is_pending = true;
		this.#pending_effect = branch(() => pending(this.#anchor));
		queue_micro_task(() => {
			if (this.#is_destroyed()) return;
			var fragment = this.#offscreen_fragment = document.createDocumentFragment();
			var anchor = create_text();
			var handled = false;
			fragment.append(anchor);
			this.#main_effect = this.#run(() => {
				try {
					return branch(() => this.#children(anchor));
				} catch (error) {
					try {
						this.error(error);
						handled = true;
					} catch (error) {
						invoke_error_boundary(error, this.#effect.parent);
					}
					return null;
				}
			});
			if (this.#main_effect === null) {
				this.#offscreen_fragment = null;
				if (handled) this.#resolve(current_batch);
				return;
			}
			if (this.#pending_count === 0) {
				this.#anchor.before(fragment);
				this.#offscreen_fragment = null;
				pause_effect(this.#pending_effect, () => {
					this.#pending_effect = null;
				});
				this.#resolve(current_batch);
			}
		});
	}
	#render() {
		try {
			this.is_pending = this.has_pending_snippet();
			this.#pending_count = 0;
			this.#local_pending_count = 0;
			this.#main_effect = branch(() => {
				this.#children(this.#anchor);
			});
			if (this.#pending_count > 0) {
				var fragment = this.#offscreen_fragment = document.createDocumentFragment();
				move_effect(this.#main_effect, fragment);
				const pending = this.#props.pending;
				this.#pending_effect = branch(() => pending(this.#anchor));
			} else this.#resolve(current_batch);
		} catch (error) {
			this.error(error);
		}
	}
	/**
	* @param {Batch} batch
	*/
	#resolve(batch) {
		this.is_pending = false;
		batch.transfer_reactions(this.#dirty_reactions);
	}
	/**
	* Defer an effect inside a pending boundary until the boundary resolves
	* @param {Effect} effect
	*/
	defer_effect(effect) {
		defer_effect(effect, this.#dirty_reactions);
	}
	/**
	* Returns `false` if the effect exists inside a boundary whose pending snippet is shown
	* @returns {boolean}
	*/
	is_rendered() {
		return !this.is_pending && (!this.parent || this.parent.is_rendered());
	}
	has_pending_snippet() {
		return !!this.#props.pending;
	}
	/**
	* @template T
	* @param {() => T} fn
	*/
	#run(fn) {
		var previous_effect = active_effect;
		var previous_reaction = active_reaction;
		var previous_ctx = component_context;
		set_active_effect(this.#effect);
		set_active_reaction(this.#effect);
		set_component_context(this.#effect.ctx);
		try {
			Batch.ensure();
			return fn();
		} finally {
			set_active_effect(previous_effect);
			set_active_reaction(previous_reaction);
			set_component_context(previous_ctx);
		}
	}
	/**
	* Updates the pending count associated with the currently visible pending snippet,
	* if any, such that we can replace the snippet with content once work is done
	* @param {1 | -1} d
	* @param {Batch} batch
	*/
	#update_pending_count(d, batch) {
		if (!this.has_pending_snippet()) {
			if (this.parent) this.parent.#update_pending_count(d, batch);
			return;
		}
		this.#pending_count += d;
		if (this.#pending_count === 0) {
			this.#resolve(batch);
			if (this.#pending_effect) pause_effect(this.#pending_effect, () => {
				this.#pending_effect = null;
			});
			if (this.#offscreen_fragment) {
				this.#anchor.before(this.#offscreen_fragment);
				this.#offscreen_fragment = null;
			}
		}
	}
	/**
	* Update the source that powers `$effect.pending()` inside this boundary,
	* and controls when the current `pending` snippet (if any) is removed.
	* Do not call from inside the class
	* @param {1 | -1} d
	* @param {Batch} batch
	*/
	update_pending_count(d, batch) {
		this.#update_pending_count(d, batch);
		this.#local_pending_count += d;
		if (!this.#effect_pending || this.#pending_count_update_queued) return;
		this.#pending_count_update_queued = true;
		queue_micro_task(() => {
			this.#pending_count_update_queued = false;
			if (this.#effect_pending) internal_set(this.#effect_pending, this.#local_pending_count);
		});
	}
	get_effect_pending() {
		this.#effect_pending_subscriber();
		return get(this.#effect_pending);
	}
	/** @param {unknown} error */
	error(error) {
		if (error === HYDRATION_ERROR) throw error;
		if (!this.#props.onerror && !this.#props.failed) throw error;
		if (current_batch?.is_fork) {
			if (this.#main_effect) current_batch.skip_effect(this.#main_effect);
			if (this.#pending_effect) current_batch.skip_effect(this.#pending_effect);
			if (this.#failed_effect) current_batch.skip_effect(this.#failed_effect);
			current_batch.oncommit(() => {
				if (!this.#is_destroyed()) this.#handle_error(error);
			});
		} else this.#handle_error(error);
	}
	/**
	* @param {unknown} error
	*/
	#handle_error(error) {
		if (this.#main_effect) {
			destroy_effect(this.#main_effect);
			this.#main_effect = null;
		}
		if (this.#pending_effect) {
			destroy_effect(this.#pending_effect);
			this.#pending_effect = null;
		}
		if (this.#failed_effect) {
			destroy_effect(this.#failed_effect);
			this.#failed_effect = null;
		}
		if (hydrating) {
			set_hydrate_node(this.#hydrate_open);
			next$1();
			set_hydrate_node(skip_nodes());
		}
		let failed = this.#props.failed;
		/** @param {unknown} transformed_error */
		const handle_error_result = (transformed_error) => {
			if (this.#is_destroyed()) return;
			const { reset, invoke_onerror } = this.#create_reset(transformed_error);
			invoke_onerror();
			if (failed && !this.#is_destroyed()) this.#failed_effect = this.#run(() => {
				try {
					return branch(() => {
						var effect = active_effect;
						effect.b = this;
						effect.f |= 128;
						failed(this.#anchor, () => transformed_error, () => reset);
					});
				} catch (error) {
					invoke_error_boundary(error, this.#effect.parent);
					return null;
				}
			});
		};
		queue_micro_task(() => {
			if (this.#is_destroyed()) return;
			/** @type {unknown} */
			var result;
			try {
				result = this.transform_error(error);
			} catch (e) {
				invoke_error_boundary(e, this.#effect && this.#effect.parent);
				return;
			}
			if (result !== null && typeof result === "object" && typeof result.then === "function")
 /** @type {any} */ result.then(
				handle_error_result,
				/** @param {unknown} e */
				(e) => invoke_error_boundary(e, this.#effect && this.#effect.parent)
			);
			else handle_error_result(result);
		});
	}
};
/**
* @param {Element} text
* @param {string} value
* @returns {void}
*/
function set_text(text, value) {
	var str = value == null ? "" : typeof value === "object" ? `${value}` : value;
	if (str !== (text[TEXT_CACHE] ??= text.nodeValue)) {
		/** @type {any} */ text[TEXT_CACHE] = str;
		text.nodeValue = `${str}`;
	}
}
/**
* Mounts a component to the given target and returns the exports and potentially the props (if compiled with `accessors: true`) of the component.
* Transitions will play during the initial render unless the `intro` option is set to `false`.
*
* @template {Record<string, any>} Props
* @template {Record<string, any>} Exports
* @param {ComponentType<SvelteComponent<Props>> | Component<Props, Exports, any>} component
* @param {MountOptions<Props>} options
* @returns {Exports}
*/
function mount(component, options) {
	return _mount(component, options);
}
/** @type {Map<EventTarget, Map<string, number>>} */
var listeners = /* @__PURE__ */ new Map();
/**
* @template {Record<string, any>} Exports
* @param {ComponentType<SvelteComponent<any>> | Component<any>} Component
* @param {MountOptions} options
* @returns {Exports}
*/
function _mount(Component, { target, anchor, props = {}, events, context, intro = true, transformError }) {
	init_operations();
	/** @type {Exports} */
	var component = void 0;
	var unmount = component_root(() => {
		var anchor_node = anchor ?? target.appendChild(create_text());
		boundary(anchor_node, { pending: () => {} }, (anchor_node) => {
			push({});
			var ctx = component_context;
			if (context) ctx.c = context;
			if (events)
 /** @type {any} */ props.$$events = events;
			if (hydrating) assign_nodes(anchor_node, null);
			component = Component(anchor_node, props) || mark_as_component();
			if (hydrating) {
				/** @type {Effect & { nodes: EffectNodes }} */ active_effect.nodes.end = hydrate_node;
				if (hydrate_node === null || hydrate_node.nodeType !== 8 || hydrate_node.data !== "]") {
					hydration_mismatch();
					throw HYDRATION_ERROR;
				}
			}
			pop();
		}, transformError);
		/** @type {Set<string>} */
		var registered_events = /* @__PURE__ */ new Set();
		/** @param {Array<string>} events */
		var event_handle = (events) => {
			for (var i = 0; i < events.length; i++) {
				var event_name = events[i];
				if (registered_events.has(event_name)) continue;
				registered_events.add(event_name);
				var passive = is_passive_event(event_name);
				for (const node of [target, document]) {
					var counts = listeners.get(node);
					if (counts === void 0) {
						counts = /* @__PURE__ */ new Map();
						listeners.set(node, counts);
					}
					var count = counts.get(event_name);
					if (count === void 0) {
						node.addEventListener(event_name, handle_event_propagation, { passive });
						counts.set(event_name, 1);
					} else counts.set(event_name, count + 1);
				}
			}
		};
		event_handle(array_from(all_registered_events));
		root_event_handles.add(event_handle);
		return () => {
			for (var event_name of registered_events) for (const node of [target, document]) {
				var counts = listeners.get(node);
				var count = counts.get(event_name);
				if (--count == 0) {
					node.removeEventListener(event_name, handle_event_propagation);
					counts.delete(event_name);
					if (counts.size === 0) listeners.delete(node);
				} else counts.set(event_name, count);
			}
			root_event_handles.delete(event_handle);
			if (anchor_node !== anchor) anchor_node.parentNode?.removeChild(anchor_node);
		};
	});
	mounted_components.set(component, unmount);
	return component;
}
/**
* References of the components that were mounted or hydrated.
* Uses a `WeakMap` to avoid memory leaks.
*/
var mounted_components = /* @__PURE__ */ new WeakMap();
// node_modules/svelte/src/internal/client/dom/blocks/branches.js
/** @import { Effect, TemplateNode } from '#client' */
/**
* @typedef {{ effect: Effect, fragment: DocumentFragment }} Branch
*/
/**
* @template Key
*/
var BranchManager = class {
	/** @type {TemplateNode} */
	anchor;
	/** @type {Map<Batch, Key>} */
	#batches = /* @__PURE__ */ new Map();
	/**
	* Map of keys to effects that are currently rendered in the DOM.
	* These effects are visible and actively part of the document tree.
	* Example:
	* ```
	* {#if condition}
	* 	foo
	* {:else}
	* 	bar
	* {/if}
	* ```
	* Can result in the entries `true->Effect` and `false->Effect`
	* @type {Map<Key, Effect>}
	*/
	#onscreen = /* @__PURE__ */ new Map();
	/**
	* Similar to #onscreen with respect to the keys, but contains branches that are not yet
	* in the DOM, because their insertion is deferred.
	* @type {Map<Key, Branch>}
	*/
	#offscreen = /* @__PURE__ */ new Map();
	/**
	* Keys of effects that are currently outroing
	* @type {Set<Key>}
	*/
	#outroing = /* @__PURE__ */ new Set();
	/**
	* Whether to pause (i.e. outro) on change, or destroy immediately.
	* This is necessary for `<svelte:element>`
	*/
	#transition = true;
	/**
	* @param {TemplateNode} anchor
	* @param {boolean} transition
	*/
	constructor(anchor, transition = true) {
		this.anchor = anchor;
		this.#transition = transition;
	}
	/**
	* @param {Batch} batch
	*/
	#commit = (batch) => {
		if (!this.#batches.has(batch)) return;
		var key = this.#batches.get(batch);
		var onscreen = this.#onscreen.get(key);
		if (onscreen) {
			resume_effect(onscreen);
			this.#outroing.delete(key);
		} else {
			var offscreen = this.#offscreen.get(key);
			if (offscreen) {
				resume_effect(offscreen.effect);
				this.#onscreen.set(key, offscreen.effect);
				this.#offscreen.delete(key);
				/** @type {TemplateNode} */ offscreen.fragment.lastChild.remove();
				this.anchor.before(offscreen.fragment);
				onscreen = offscreen.effect;
			}
		}
		for (const [b, k] of this.#batches) {
			this.#batches.delete(b);
			if (b === batch) break;
			const offscreen = this.#offscreen.get(k);
			if (offscreen) {
				destroy_effect(offscreen.effect);
				this.#offscreen.delete(k);
			}
		}
		for (const [k, effect] of this.#onscreen) {
			if (k === key || this.#outroing.has(k)) continue;
			const on_destroy = () => {
				if (Array.from(this.#batches.values()).includes(k)) {
					var fragment = document.createDocumentFragment();
					move_effect(effect, fragment);
					fragment.append(create_text());
					this.#offscreen.set(k, {
						effect,
						fragment
					});
				} else destroy_effect(effect);
				this.#outroing.delete(k);
				this.#onscreen.delete(k);
			};
			if (this.#transition || !onscreen) {
				this.#outroing.add(k);
				pause_effect(effect, on_destroy, false);
			} else on_destroy();
		}
	};
	/**
	* @param {Batch} batch
	*/
	#discard = (batch) => {
		this.#batches.delete(batch);
		const keys = Array.from(this.#batches.values());
		for (const [k, branch] of this.#offscreen) if (!keys.includes(k)) {
			destroy_effect(branch.effect);
			this.#offscreen.delete(k);
		}
	};
	/**
	*
	* @param {any} key
	* @param {null | ((target: TemplateNode) => void)} fn
	*/
	ensure(key, fn) {
		var batch = current_batch;
		var defer = should_defer_append();
		if (fn && !this.#onscreen.has(key) && !this.#offscreen.has(key)) {
			if (defer) {
				var fragment = document.createDocumentFragment();
				var target = create_text();
				fragment.append(target);
				this.#offscreen.set(key, {
					effect: branch(() => fn(target)),
					fragment
				});
			} else this.#onscreen.set(key, branch(() => fn(this.anchor)));
		}
		this.#batches.set(batch, key);
		if (defer) {
			for (const [k, effect] of this.#onscreen) if (k === key) batch.unskip_effect(effect);
			else batch.skip_effect(effect);
			for (const [k, branch] of this.#offscreen) if (k === key) batch.unskip_effect(branch.effect);
			else batch.skip_effect(branch.effect);
			batch.oncommit(this.#commit);
			batch.ondiscard(this.#discard);
		} else {
			if (hydrating) this.anchor = hydrate_node;
			this.#commit(batch);
		}
	}
};
// node_modules/svelte/src/internal/client/dom/blocks/snippet.js
/** @import { Snippet } from 'svelte' */
/** @import { TemplateNode } from '#client' */
/** @import { Getters } from '#shared' */
/**
* @template {(node: TemplateNode, ...args: any[]) => void} SnippetFn
* @param {TemplateNode} node
* @param {() => SnippetFn | null | undefined} get_snippet
* @param {(() => any)[]} args
* @returns {void}
*/
function snippet(node, get_snippet, ...args) {
	var branches = new BranchManager(node);
	block(() => {
		const snippet = get_snippet() ?? null;
		branches.ensure(snippet, snippet && ((anchor) => snippet(anchor, ...args)));
	}, EFFECT_TRANSPARENT);
}
// node_modules/svelte/src/internal/client/dom/blocks/if.js
/** @import { TemplateNode } from '#client' */
/**
* @param {TemplateNode} node
* @param {(branch: (fn: (anchor: Node) => void, key?: number | false) => void) => void} fn
* @param {boolean} [elseif] True if this is an `{:else if ...}` block rather than an `{#if ...}`, as that affects which transitions are considered 'local'
* @returns {void}
*/
function if_block(node, fn, elseif = false) {
	/** @type {TemplateNode | undefined} */
	var marker;
	if (hydrating) {
		marker = hydrate_node;
		hydrate_next();
	}
	var branches = new BranchManager(node);
	var flags = elseif ? EFFECT_TRANSPARENT : 0;
	/**
	* @param {number | false} key
	* @param {null | ((anchor: Node) => void)} fn
	*/
	function update_branch(key, fn) {
		if (hydrating) {
			var data = read_hydration_instruction(marker);
			if (key !== parseInt(data.substring(1))) {
				var anchor = skip_nodes();
				set_hydrate_node(anchor);
				branches.anchor = anchor;
				set_hydrating(false);
				branches.ensure(key, fn);
				set_hydrating(true);
				return;
			}
		}
		branches.ensure(key, fn);
	}
	block(() => {
		var has_branch = false;
		fn((fn, key = 0) => {
			has_branch = true;
			update_branch(key, fn);
		});
		if (!has_branch) update_branch(-1, null);
	}, flags);
}
// node_modules/svelte/src/internal/client/dom/blocks/each.js
/** @import { EachItem, EachOutroGroup, EachState, Effect, EffectNodes, MaybeSource, TemplateNode, TransitionManager } from '#client' */
/** @import { Batch } from '../../reactivity/batch.js'; */
/**
* @param {any} _
* @param {number} i
*/
function index(_, i) {
	return i;
}
/**
* Pause multiple effects simultaneously, and coordinate their
* subsequent destruction. Used in each blocks
* @param {EachState} state
* @param {Effect[]} to_destroy
* @param {null | Node} controlled_anchor
*/
function pause_effects(state, to_destroy, controlled_anchor) {
	/** @type {TransitionManager[]} */
	var transitions = [];
	var length = to_destroy.length;
	/** @type {EachOutroGroup} */
	var group;
	var remaining = to_destroy.length;
	for (var i = 0; i < length; i++) {
		let effect = to_destroy[i];
		pause_effect(effect, () => {
			if (group) {
				group.pending.delete(effect);
				group.done.add(effect);
				if (group.pending.size === 0) {
					var groups = state.outrogroups;
					destroy_effects(state, array_from(group.done));
					groups.delete(group);
					if (groups.size === 0) state.outrogroups = null;
				}
			} else remaining -= 1;
		}, false);
	}
	if (remaining === 0) {
		var fast_path = transitions.length === 0 && controlled_anchor !== null && state.pending.size === 0;
		if (fast_path) {
			var anchor = controlled_anchor;
			var parent_node = anchor.parentNode;
			clear_text_content(parent_node);
			parent_node.append(anchor);
			state.items.clear();
		}
		destroy_effects(state, to_destroy, !fast_path);
	} else {
		group = {
			pending: new Set(to_destroy),
			done: /* @__PURE__ */ new Set()
		};
		(state.outrogroups ??= /* @__PURE__ */ new Set()).add(group);
	}
}
/**
* @param {EachState} state
* @param {Effect[]} to_destroy
* @param {boolean} remove_dom
*/
function destroy_effects(state, to_destroy, remove_dom = true) {
	/** @type {Set<Effect> | undefined} */
	var preserved_effects;
	if (state.pending.size > 0) {
		preserved_effects = /* @__PURE__ */ new Set();
		for (const keys of state.pending.values()) for (const key of keys) preserved_effects.add(
			/** @type {EachItem} */
			state.items.get(key).e
		);
	}
	for (var i = 0; i < to_destroy.length; i++) {
		var e = to_destroy[i];
		if (preserved_effects?.has(e)) {
			e.f |= EFFECT_OFFSCREEN;
			move_effect(e, document.createDocumentFragment());
		} else destroy_effect(to_destroy[i], remove_dom);
	}
}
/** @type {TemplateNode} */
var offscreen_anchor;
/**
* @template V
* @param {Element | Comment} node The next sibling node, or the parent node if this is a 'controlled' block
* @param {number} flags
* @param {() => V[]} get_collection
* @param {(value: V, index: number) => any} get_key
* @param {(anchor: Node, item: MaybeSource<V>, index: MaybeSource<number>) => void} render_fn
* @param {null | ((anchor: Node) => void)} fallback_fn
* @returns {void}
*/
function each(node, flags, get_collection, get_key, render_fn, fallback_fn = null) {
	var anchor = node;
	/** @type {Map<any, EachItem>} */
	var items = /* @__PURE__ */ new Map();
	if ((flags & 4) !== 0) {
		var parent_node = node;
		anchor = hydrating ? set_hydrate_node(/* @__PURE__ */ get_first_child(parent_node)) : parent_node.appendChild(create_text());
	}
	if (hydrating) hydrate_next();
	/** @type {Effect | null} */
	var fallback = null;
	var each_array = /* @__PURE__ */ derived_safe_equal(() => {
		var collection = get_collection();
		return is_array(collection) ? collection : collection == null ? [] : array_from(collection);
	});
	/** @type {Map<Batch, Set<any>>} */
	var pending = /* @__PURE__ */ new Map();
	var first_run = true;
	/**
	* @param {Batch} batch
	*/
	function commit(batch) {
		if ((state.effect.f & 16384) !== 0) return;
		state.pending.delete(batch);
		var array = get(each_array);
		state.fallback = fallback;
		reconcile(state, array, anchor, flags, get_key);
		if (fallback !== null) {
			if (array.length === 0) {
				if ((fallback.f & 33554432) === 0) resume_effect(fallback);
				else {
					fallback.f ^= EFFECT_OFFSCREEN;
					move(fallback, null, anchor);
				}
			} else pause_effect(fallback, () => {
				fallback = null;
			});
		}
	}
	/**
	* @param {Batch} batch
	*/
	function discard(batch) {
		state.pending.delete(batch);
	}
	/** @type {EachState} */
	var state = {
		effect: block(() => {
			var array = get(each_array);
			var length = array.length;
			/** `true` if there was a hydration mismatch. Needs to be a `let` or else it isn't treeshaken out */
			let mismatch = false;
			if (hydrating) {
				if (read_hydration_instruction(anchor) === "[!" !== (length === 0)) {
					anchor = skip_nodes();
					set_hydrate_node(anchor);
					set_hydrating(false);
					mismatch = true;
				}
			}
			var keys = /* @__PURE__ */ new Set();
			var batch = current_batch;
			var defer = should_defer_append();
			for (var index = 0; index < length; index += 1) {
				if (hydrating && hydrate_node.nodeType === 8 && hydrate_node.data === "]") {
					anchor = hydrate_node;
					mismatch = true;
					set_hydrating(false);
				}
				var value = array[index];
				var key = get_key(value, index);
				var item = first_run ? null : items.get(key);
				if (item) {
					if (item.v) internal_set(item.v, value);
					if (item.i) internal_set(item.i, index);
					if (defer) batch.unskip_effect(item.e);
				} else {
					item = create_item(items, first_run ? anchor : offscreen_anchor ??= create_text(), value, key, index, render_fn, flags, get_collection);
					if (!first_run) item.e.f |= EFFECT_OFFSCREEN;
					items.set(key, item);
				}
				keys.add(key);
			}
			if (length === 0 && fallback_fn && !fallback) {
				if (first_run) fallback = branch(() => fallback_fn(anchor));
				else {
					fallback = branch(() => fallback_fn(offscreen_anchor ??= create_text()));
					fallback.f |= EFFECT_OFFSCREEN;
				}
			}
			if (length > keys.size) each_key_duplicate("", "", "");
			if (hydrating && length > 0) set_hydrate_node(skip_nodes());
			if (!first_run) {
				pending.set(batch, keys);
				if (defer) {
					for (const [key, item] of items) if (!keys.has(key)) batch.skip_effect(item.e);
					batch.oncommit(commit);
					batch.ondiscard(discard);
				} else commit(batch);
			}
			if (mismatch) set_hydrating(true);
			get(each_array);
		}),
		flags,
		items,
		pending,
		outrogroups: null,
		fallback
	};
	first_run = false;
	if (hydrating) anchor = hydrate_node;
}
/**
* Skip past any non-branch effects (which could be created with `createSubscriber`, for example) to find the next branch effect
* @param {Effect | null} effect
* @returns {Effect | null}
*/
function skip_to_branch(effect) {
	while (effect !== null && (effect.f & 32) === 0) effect = effect.next;
	return effect;
}
/**
* Add, remove, or reorder items output by an each block as its input changes
* @template V
* @param {EachState} state
* @param {Array<V>} array
* @param {Element | Comment | Text} anchor
* @param {number} flags
* @param {(value: V, index: number) => any} get_key
* @returns {void}
*/
function reconcile(state, array, anchor, flags, get_key) {
	var is_animated = (flags & 8) !== 0;
	var length = array.length;
	var items = state.items;
	var current = skip_to_branch(state.effect.first);
	/** @type {undefined | Set<Effect>} */
	var seen;
	/** @type {Effect | null} */
	var prev = null;
	/** @type {undefined | Set<Effect>} */
	var to_animate;
	/** @type {Effect[]} */
	var matched = [];
	/** @type {Effect[]} */
	var stashed = [];
	/** @type {V} */
	var value;
	/** @type {any} */
	var key;
	/** @type {Effect | undefined} */
	var effect;
	/** @type {number} */
	var i;
	if (is_animated) for (i = 0; i < length; i += 1) {
		value = array[i];
		key = get_key(value, i);
		effect = items.get(key).e;
		if ((effect.f & 33554432) === 0) {
			effect.nodes?.a?.measure();
			(to_animate ??= /* @__PURE__ */ new Set()).add(effect);
		}
	}
	for (i = 0; i < length; i += 1) {
		value = array[i];
		key = get_key(value, i);
		effect = items.get(key).e;
		if (state.outrogroups !== null) for (const group of state.outrogroups) {
			group.pending.delete(effect);
			group.done.delete(effect);
		}
		if ((effect.f & 8192) !== 0) {
			resume_effect(effect);
			if (is_animated) {
				effect.nodes?.a?.unfix();
				(to_animate ??= /* @__PURE__ */ new Set()).delete(effect);
			}
		}
		if ((effect.f & 33554432) !== 0) {
			effect.f ^= EFFECT_OFFSCREEN;
			if (effect === current) move(effect, null, anchor);
			else {
				var next = prev ? prev.next : current;
				if (effect === state.effect.last) state.effect.last = effect.prev;
				if (effect.prev) effect.prev.next = effect.next;
				if (effect.next) effect.next.prev = effect.prev;
				link(state, prev, effect);
				link(state, effect, next);
				move(effect, next, anchor);
				prev = effect;
				matched = [];
				stashed = [];
				current = skip_to_branch(prev.next);
				continue;
			}
		}
		if (effect !== current) {
			if (seen !== void 0 && seen.has(effect)) {
				if (matched.length < stashed.length) {
					var start = stashed[0];
					var j;
					prev = start.prev;
					var a = matched[0];
					var b = matched[matched.length - 1];
					for (j = 0; j < matched.length; j += 1) move(matched[j], start, anchor);
					for (j = 0; j < stashed.length; j += 1) seen.delete(stashed[j]);
					link(state, a.prev, b.next);
					link(state, prev, a);
					link(state, b, start);
					current = start;
					prev = b;
					i -= 1;
					matched = [];
					stashed = [];
				} else {
					seen.delete(effect);
					move(effect, current, anchor);
					link(state, effect.prev, effect.next);
					link(state, effect, prev === null ? state.effect.first : prev.next);
					link(state, prev, effect);
					prev = effect;
				}
				continue;
			}
			matched = [];
			stashed = [];
			while (current !== null && current !== effect) {
				(seen ??= /* @__PURE__ */ new Set()).add(current);
				stashed.push(current);
				current = skip_to_branch(current.next);
			}
			if (current === null) continue;
		}
		if ((effect.f & 33554432) === 0) matched.push(effect);
		prev = effect;
		current = skip_to_branch(effect.next);
	}
	if (state.outrogroups !== null) {
		for (const group of state.outrogroups) if (group.pending.size === 0) {
			destroy_effects(state, array_from(group.done));
			state.outrogroups?.delete(group);
		}
		if (state.outrogroups.size === 0) state.outrogroups = null;
	}
	if (current !== null || seen !== void 0) {
		/** @type {Effect[]} */
		var to_destroy = [];
		if (seen !== void 0) {
			for (effect of seen) if ((effect.f & 8192) === 0) to_destroy.push(effect);
		}
		while (current !== null) {
			if ((current.f & 8192) === 0 && current !== state.fallback) to_destroy.push(current);
			current = skip_to_branch(current.next);
		}
		var destroy_length = to_destroy.length;
		if (destroy_length > 0) {
			var controlled_anchor = (flags & 4) !== 0 && length === 0 ? anchor : null;
			if (is_animated) {
				for (i = 0; i < destroy_length; i += 1) to_destroy[i].nodes?.a?.measure();
				for (i = 0; i < destroy_length; i += 1) to_destroy[i].nodes?.a?.fix();
			}
			pause_effects(state, to_destroy, controlled_anchor);
		}
	}
	if (is_animated) queue_micro_task(() => {
		if (to_animate === void 0) return;
		for (effect of to_animate) effect.nodes?.a?.apply();
	});
}
/**
* @template V
* @param {Map<any, EachItem>} items
* @param {Node} anchor
* @param {V} value
* @param {unknown} key
* @param {number} index
* @param {(anchor: Node, item: MaybeSource<V>, index: MaybeSource<number>, collection: () => V[]) => void} render_fn
* @param {number} flags
* @param {() => V[]} get_collection
* @returns {EachItem}
*/
function create_item(items, anchor, value, key, index, render_fn, flags, get_collection) {
	var v = (flags & 1) !== 0 ? (flags & 16) === 0 ? /* @__PURE__ */ mutable_source(value, false, false) : source(value) : null;
	var i = (flags & 2) !== 0 ? source(index) : null;
	return {
		v,
		i,
		e: branch(() => {
			render_fn(anchor, v ?? value, i ?? index, get_collection);
			return () => {
				items.delete(key);
			};
		})
	};
}
/**
* @param {Effect} effect
* @param {Effect | null} next
* @param {Text | Element | Comment} anchor
*/
function move(effect, next, anchor) {
	if (!effect.nodes) return;
	var node = effect.nodes.start;
	var end = effect.nodes.end;
	var dest = next && (next.f & 33554432) === 0 ? next.nodes.start : anchor;
	while (node !== null) {
		var next_node = /* @__PURE__ */ get_next_sibling(node);
		dest.before(node);
		if (node === end) return;
		node = next_node;
	}
}
/**
* @param {EachState} state
* @param {Effect | null} prev
* @param {Effect | null} next
*/
function link(state, prev, next) {
	if (prev === null) state.effect.first = next;
	else prev.next = next;
	if (next === null) state.effect.last = prev;
	else next.prev = prev;
}
/**
* @param {Element | Text | Comment} node
* @param {() => string | TrustedHTML} get_value
* @param {boolean} [is_controlled]
* @param {boolean} [svg]
* @param {boolean} [mathml]
* @param {boolean} [skip_warning]
* @returns {void}
*/
function html(node, get_value, is_controlled = false, svg = false, mathml = false, skip_warning = false) {
	var anchor = node;
	/** @type {string | TrustedHTML} */
	var value = "";
	if (is_controlled) {
		var parent_node = node;
		if (hydrating) anchor = set_hydrate_node(/* @__PURE__ */ get_first_child(parent_node));
	}
	template_effect(() => {
		var effect = active_effect;
		if (value === (value = get_value() ?? "")) {
			if (hydrating) hydrate_next();
			return;
		}
		if (is_controlled && !hydrating) {
			effect.nodes = null;
			parent_node.innerHTML = value;
			if (value !== "") assign_nodes(/* @__PURE__ */ get_first_child(parent_node), parent_node.lastChild);
			return;
		}
		if (effect.nodes !== null) {
			remove_effect_dom(effect.nodes.start, effect.nodes.end);
			effect.nodes = null;
		}
		if (value === "") return;
		if (hydrating) {
			hydrate_node.data;
			/** @type {TemplateNode | null} */
			var next = hydrate_next();
			var last = next;
			while (next !== null && (next.nodeType !== 8 || next.data !== "")) {
				last = next;
				next = /* @__PURE__ */ get_next_sibling(next);
			}
			if (next === null) {
				hydration_mismatch();
				throw HYDRATION_ERROR;
			}
			assign_nodes(hydrate_node, last);
			anchor = set_hydrate_node(next);
			return;
		}
		var wrapper = create_element(svg ? "svg" : mathml ? "math" : "template", svg ? NAMESPACE_SVG : mathml ? NAMESPACE_MATHML : void 0);
		wrapper.innerHTML = value;
		/** @type {DocumentFragment | Element} */
		var node = svg || mathml ? wrapper : /** @type {HTMLTemplateElement} */ wrapper.content;
		assign_nodes(/* @__PURE__ */ get_first_child(node), node.lastChild);
		if (svg || mathml) while (/* @__PURE__ */ get_first_child(node)) anchor.before(/* @__PURE__ */ get_first_child(node));
		else anchor.before(node);
	});
}
// node_modules/svelte/src/internal/client/dom/css.js
/**
* @param {Node} anchor
* @param {{ hash: string, code: string }} css
*/
function append_styles$1(anchor, css) {
	effect(() => {
		anchor = active_effect?.parent?.nodes?.start ?? anchor;
		var root = anchor.getRootNode();
		var target = root.host ? root : /** @type {Document} */ root.head ?? root.ownerDocument.head;
		if (!target.querySelector("#" + css.hash)) {
			const style = create_element("style");
			style.id = css.hash;
			style.textContent = css.code;
			target.appendChild(style);
		}
	});
}
// node_modules/clsx/dist/clsx.mjs
function r(e) {
	var t, f, n = "";
	if ("string" == typeof e || "number" == typeof e) n += e;
	else if ("object" == typeof e) if (Array.isArray(e)) {
		var o = e.length;
		for (t = 0; t < o; t++) e[t] && (f = r(e[t])) && (n && (n += " "), n += f);
	} else for (f in e) e[f] && (n && (n += " "), n += f);
	return n;
}
function clsx$1() {
	for (var e, t, f = 0, n = "", o = arguments.length; f < o; f++) (e = arguments[f]) && (t = r(e)) && (n && (n += " "), n += t);
	return n;
}
// node_modules/svelte/src/internal/shared/attributes.js
/**
* Small wrapper around clsx to preserve Svelte's (weird) handling of falsy values.
* TODO Svelte 6 revisit this, and likely turn all falsy values into the empty string (what clsx also does)
* @param  {any} value
*/
function clsx(value) {
	if (typeof value === "object") return clsx$1(value);
	else return value ?? "";
}
var whitespace = [..." 	\n\r\f\xA0\v﻿"];
/**
* @param {any} value
* @param {string | null} [hash]
* @param {Record<string, boolean>} [directives]
* @returns {string | null}
*/
function to_class(value, hash, directives) {
	var classname = value == null ? "" : "" + value;
	if (hash) classname = classname ? classname + " " + hash : hash;
	if (directives) {
		for (var key of Object.keys(directives)) if (directives[key]) classname = classname ? classname + " " + key : key;
		else if (classname.length) {
			var len = key.length;
			var a = 0;
			while ((a = classname.indexOf(key, a)) >= 0) {
				var b = a + len;
				if ((a === 0 || whitespace.includes(classname[a - 1])) && (b === classname.length || whitespace.includes(classname[b]))) classname = (a === 0 ? "" : classname.substring(0, a)) + classname.substring(b + 1);
				else a = b;
			}
		}
	}
	return classname === "" ? null : classname;
}
/**
*
* @param {Record<string,any>} styles
* @param {boolean} important
*/
function append_styles(styles, important = false) {
	var separator = important ? " !important;" : ";";
	var css = "";
	for (var key of Object.keys(styles)) {
		var value = styles[key];
		if (value != null && value !== "") css += " " + key + ": " + value + separator;
	}
	return css;
}
/**
* @param {string} name
* @returns {string}
*/
function to_css_name(name) {
	if (name[0] !== "-" || name[1] !== "-") return name.toLowerCase();
	return name;
}
/**
* @param {any} value
* @param {Record<string, any> | [Record<string, any>, Record<string, any>]} [styles]
* @returns {string | null}
*/
function to_style(value, styles) {
	if (styles) {
		var new_style = "";
		/** @type {Record<string,any> | undefined} */
		var normal_styles;
		/** @type {Record<string,any> | undefined} */
		var important_styles;
		if (Array.isArray(styles)) {
			normal_styles = styles[0];
			important_styles = styles[1];
		} else normal_styles = styles;
		if (value) {
			value = String(value).replaceAll(/\/\*.*?\*\//g, "").trim();
			/** @type {boolean | '"' | "'"} */
			var in_str = false;
			var in_apo = 0;
			var in_comment = false;
			var reserved_names = [];
			if (normal_styles) reserved_names.push(...Object.keys(normal_styles).map(to_css_name));
			if (important_styles) reserved_names.push(...Object.keys(important_styles).map(to_css_name));
			var start_index = 0;
			var name_index = -1;
			const len = value.length;
			for (var i = 0; i < len; i++) {
				var c = value[i];
				if (in_comment) {
					if (c === "/" && value[i - 1] === "*") in_comment = false;
				} else if (in_str) {
					if (in_str === c) in_str = false;
				} else if (c === "/" && value[i + 1] === "*") in_comment = true;
				else if (c === "\"" || c === "'") in_str = c;
				else if (c === "(") in_apo++;
				else if (c === ")") in_apo--;
				if (!in_comment && in_str === false && in_apo === 0) {
					if (c === ":" && name_index === -1) name_index = i;
					else if (c === ";" || i === len - 1) {
						if (name_index !== -1) {
							var name = to_css_name(value.substring(start_index, name_index).trim());
							if (!reserved_names.includes(name)) {
								if (c !== ";") i++;
								var property = value.substring(start_index, i).trim();
								new_style += " " + property + ";";
							}
						}
						start_index = i + 1;
						name_index = -1;
					}
				}
			}
		}
		if (normal_styles) new_style += append_styles(normal_styles);
		if (important_styles) new_style += append_styles(important_styles, true);
		new_style = new_style.trim();
		return new_style === "" ? null : new_style;
	}
	return value == null ? null : String(value);
}
// node_modules/svelte/src/internal/client/dom/elements/class.js
/**
* @param {Element} dom
* @param {boolean | number} is_html
* @param {string | null} value
* @param {string} [hash]
* @param {Record<string, any>} [prev_classes]
* @param {Record<string, any>} [next_classes]
* @returns {Record<string, boolean> | undefined}
*/
function set_class(dom, is_html, value, hash, prev_classes, next_classes) {
	var prev = dom[CLASS_CACHE];
	if (hydrating || prev !== value || prev === void 0) {
		var next_class_name = to_class(value, hash, next_classes);
		if (!hydrating || next_class_name !== dom.getAttribute("class")) {
			if (next_class_name == null) dom.removeAttribute("class");
			else if (is_html) dom.className = next_class_name;
			else dom.setAttribute("class", next_class_name);
		}
		/** @type {any} */ dom[CLASS_CACHE] = value;
	} else if (next_classes && prev_classes !== next_classes) for (var key in next_classes) {
		var is_present = !!next_classes[key];
		if (prev_classes == null || is_present !== !!prev_classes[key]) dom.classList.toggle(key, is_present);
	}
	return next_classes;
}
// node_modules/svelte/src/internal/client/dom/elements/style.js
/**
* @param {Element & ElementCSSInlineStyle} dom
* @param {Record<string, any>} prev
* @param {Record<string, any>} next
* @param {string} [priority]
*/
function update_styles(dom, prev = {}, next, priority) {
	for (var key in next) {
		var value = next[key];
		if (prev[key] !== value) {
			if (next[key] == null) dom.style.removeProperty(key);
			else dom.style.setProperty(key, value, priority);
		}
	}
}
/**
* @param {Element & ElementCSSInlineStyle} dom
* @param {string | null} value
* @param {Record<string, any> | [Record<string, any>, Record<string, any>]} [prev_styles]
* @param {Record<string, any> | [Record<string, any>, Record<string, any>]} [next_styles]
*/
function set_style(dom, value, prev_styles, next_styles) {
	var prev = dom[STYLE_CACHE];
	if (hydrating || prev !== value) {
		var next_style_attr = to_style(value, next_styles);
		if (!hydrating || next_style_attr !== dom.getAttribute("style")) {
			if (next_style_attr == null) dom.removeAttribute("style");
			else dom.style.cssText = next_style_attr;
		}
		/** @type {any} */ dom[STYLE_CACHE] = value;
	} else if (next_styles) {
		if (Array.isArray(next_styles)) {
			update_styles(dom, prev_styles?.[0], next_styles[0]);
			update_styles(dom, prev_styles?.[1], next_styles[1], "important");
		} else update_styles(dom, prev_styles, next_styles);
	}
	return next_styles;
}
// node_modules/svelte/src/internal/client/dom/elements/attributes.js
/** @import { Blocker, Effect } from '#client' */
var IS_CUSTOM_ELEMENT = Symbol("is custom element");
var IS_HTML = Symbol("is html");
var LINK_TAG = IS_XHTML ? "link" : "LINK";
/**
* The value/checked attribute in the template actually corresponds to the defaultValue property, so we need
* to remove it upon hydration to avoid a bug when someone resets the form value.
* @param {HTMLInputElement} input
* @returns {void}
*/
function remove_input_defaults(input) {
	if (!hydrating) return;
	var already_removed = false;
	var remove_defaults = () => {
		if (already_removed) return;
		already_removed = true;
		if (input.hasAttribute("value")) {
			var value = input.value;
			set_attribute(input, "value", null);
			input.value = value;
		}
		if (input.hasAttribute("checked")) {
			var checked = input.checked;
			set_attribute(input, "checked", null);
			input.checked = checked;
		}
	};
	/** @type {any} */ input[FORM_RESET_HANDLER] = remove_defaults;
	queue_micro_task(remove_defaults);
	add_form_reset_listener();
}
/**
* @param {Element} element
* @param {string} attribute
* @param {string | null} value
* @param {boolean} [skip_warning]
*/
function set_attribute(element, attribute, value, skip_warning) {
	var attributes = get_attributes(element);
	if (hydrating) {
		attributes[attribute] = element.getAttribute(attribute);
		if (attribute === "src" || attribute === "srcset" || attribute === "href" && element.nodeName === LINK_TAG) {
			if (!skip_warning);
			return;
		}
	}
	var previous = attributes[attribute];
	if (previous === (attributes[attribute] = value)) return;
	if (attribute === "loading") element[LOADING_ATTR_SYMBOL] = value;
	if (value == null) element.removeAttribute(attribute);
	else if (typeof value !== "string" && get_setters(element).has(attribute)) element[attribute] = value;
	else if (!(hydrating && (typeof value === "number" || typeof value === "boolean") && previous === String(value))) element.setAttribute(attribute, value);
}
/**
*
* @param {Element} element
*/
function get_attributes(element) {
	return element[ATTRIBUTES_CACHE] ??= {
		[IS_CUSTOM_ELEMENT]: element.nodeName.includes("-"),
		[IS_HTML]: element.namespaceURI === NAMESPACE_HTML
	};
}
/** @type {Map<string, Set<string>>} */
var setters_cache = /* @__PURE__ */ new Map();
/** @param {Element} element */
function get_setters(element) {
	var cache_key = element.getAttribute("is") || element.nodeName;
	var setters = setters_cache.get(cache_key);
	if (setters) return setters;
	setters_cache.set(cache_key, setters = /* @__PURE__ */ new Set());
	var descriptors;
	var proto = element;
	var element_proto = Element.prototype;
	while (element_proto !== proto) {
		descriptors = get_descriptors(proto);
		for (var key in descriptors) if (descriptors[key].set && key !== "innerHTML" && key !== "textContent" && key !== "innerText") setters.add(key);
		proto = get_prototype_of(proto);
	}
	return setters;
}
// node_modules/svelte/src/internal/client/dom/elements/bindings/input.js
/** @import { Batch } from '../../../reactivity/batch.js' */
/**
* @param {HTMLInputElement} input
* @param {() => unknown} get
* @param {(value: unknown) => void} set
* @returns {void}
*/
function bind_value(input, get, set = get) {
	var batches = /* @__PURE__ */ new WeakSet();
	listen_to_event_and_reset_event(input, "input", async (is_reset) => {
		/** @type {any} */
		var value = is_reset ? input.defaultValue : input.value;
		value = is_numberlike_input(input) ? to_number(value) : value;
		set(value);
		if (current_batch !== null) batches.add(current_batch);
		await tick();
		if (value !== (value = get())) {
			var start = input.selectionStart;
			var end = input.selectionEnd;
			var length = input.value.length;
			input.value = value ?? "";
			if (end !== null) {
				var new_length = input.value.length;
				if (start === end && end === length && new_length > length) {
					input.selectionStart = new_length;
					input.selectionEnd = new_length;
				} else {
					input.selectionStart = start;
					input.selectionEnd = Math.min(end, new_length);
				}
			}
		}
	});
	if (hydrating && input.defaultValue !== input.value || untrack(get) == null && input.value) {
		set(is_numberlike_input(input) ? to_number(input.value) : input.value);
		if (current_batch !== null) batches.add(current_batch);
	}
	render_effect(() => {
		var value = get();
		if (input === document.activeElement) {
			var batch = async_mode_flag ? previous_batch : current_batch;
			if (batches.has(batch)) return;
		}
		if (is_numberlike_input(input) && value === to_number(input.value)) return;
		if (input.type === "date" && !value && !input.value) return;
		if (value !== input.value) input.value = value ?? "";
	});
}
/**
* @param {HTMLInputElement} input
*/
function is_numberlike_input(input) {
	var type = input.type;
	return type === "number" || type === "range";
}
/**
* @param {string} value
*/
function to_number(value) {
	return value === "" ? null : +value;
}
// node_modules/svelte/src/internal/client/dom/elements/bindings/this.js
/** @import { ComponentContext, Effect } from '#client' */
/**
* @param {any} bound_value
* @param {Element} element_or_component
* @returns {boolean}
*/
function is_bound_this(bound_value, element_or_component) {
	return bound_value === element_or_component || bound_value?.[STATE_SYMBOL] === element_or_component;
}
/**
* @param {any} element_or_component
* @param {(value: unknown, ...parts: unknown[]) => void} update
* @param {(...parts: unknown[]) => unknown} get_value
* @param {() => unknown[]} [get_parts] Set if the this binding is used inside an each block,
* 										returns all the parts of the each block context that are used in the expression
* @returns {void}
*/
function bind_this(element_or_component = mark_as_component(), update, get_value, get_parts) {
	var component_effect = component_context.r;
	var parent = active_effect;
	effect(() => {
		/** @type {unknown[]} */
		var old_parts;
		/** @type {unknown[]} */
		var parts;
		render_effect(() => {
			old_parts = parts;
			parts = get_parts?.() || [];
			untrack(() => {
				if (!is_bound_this(get_value(...parts), element_or_component)) {
					update(element_or_component, ...parts);
					if (old_parts && is_bound_this(get_value(...old_parts), element_or_component)) update(null, ...old_parts);
				}
			});
		});
		return () => {
			let p = parent;
			while (p !== component_effect && p.parent !== null && p.parent.f & 33554432) p = p.parent;
			const teardown = () => {
				if (parts && is_bound_this(get_value(...parts), element_or_component)) update(null, ...parts);
			};
			const original_teardown = p.teardown;
			p.teardown = () => {
				teardown();
				original_teardown?.();
			};
		};
	});
	return element_or_component;
}
// node_modules/svelte/src/internal/client/reactivity/store.js
/**
* Whether or not the prop currently being read is a store binding, as in
* `<Child bind:x={$y} />`. If it is, we treat the prop as mutable even in
* runes mode, and skip `binding_property_non_reactive` validation
*/
var is_store_binding = false;
/**
* Returns a tuple that indicates whether `fn()` reads a prop that is a store binding.
* Used to prevent `binding_property_non_reactive` validation false positives and
* ensure that these props are treated as mutable even in runes mode
* @template T
* @param {() => T} fn
* @returns {[T, boolean]}
*/
function capture_store_binding(fn) {
	var previous_is_store_binding = is_store_binding;
	try {
		is_store_binding = false;
		return [fn(), is_store_binding];
	} finally {
		is_store_binding = previous_is_store_binding;
	}
}
// node_modules/svelte/src/internal/client/reactivity/props.js
/** @import { Derived, Effect, Source } from './types.js' */
/**
* This function is responsible for synchronizing a possibly bound prop with the inner component state.
* It is used whenever the compiler sees that the component writes to the prop, or when it has a default prop_value.
* @template V
* @param {Record<string, unknown>} props
* @param {string} key
* @param {number} flags
* @param {V | (() => V)} [fallback]
* @returns {(() => V | ((arg: V) => V) | ((arg: V, mutation: boolean) => V))}
*/
function prop(props, key, flags, fallback) {
	var runes = !legacy_mode_flag || (flags & 2) !== 0;
	var bindable = (flags & 8) !== 0;
	var lazy = (flags & 16) !== 0;
	var fallback_value = fallback;
	var fallback_dirty = true;
	var fallback_signal = void 0;
	var get_fallback = () => {
		if (lazy && runes) {
			fallback_signal ??= /* @__PURE__ */ derived(fallback);
			return get(fallback_signal);
		}
		if (fallback_dirty) {
			fallback_dirty = false;
			fallback_value = lazy ? untrack(fallback) : fallback;
		}
		return fallback_value;
	};
	/** @type {((v: V) => void) | undefined} */
	let setter;
	if (bindable) {
		var is_entry_props = STATE_SYMBOL in props || LEGACY_PROPS in props;
		setter = get_descriptor(props, key)?.set ?? (is_entry_props && key in props ? (v) => props[key] = v : void 0);
	}
	/** @type {V} */
	var initial_value;
	var is_store_sub = false;
	if (bindable) [initial_value, is_store_sub] = capture_store_binding(() => props[key]);
	else initial_value = props[key];
	if (initial_value === void 0 && fallback !== void 0) {
		initial_value = get_fallback();
		if (setter) {
			if (runes) props_invalid_value(key);
			setter(initial_value);
		}
	}
	/** @type {() => V} */
	var getter;
	if (runes) getter = () => {
		var value = props[key];
		if (value === void 0) return get_fallback();
		fallback_dirty = true;
		return value;
	};
	else getter = () => {
		var value = props[key];
		if (value !== void 0) fallback_value = void 0;
		return value === void 0 ? fallback_value : value;
	};
	if (runes && (flags & 4) === 0) return getter;
	if (setter) {
		var legacy_parent = props.$$legacy;
		return (function(value, mutation) {
			if (arguments.length > 0) {
				if (!runes || !mutation || legacy_parent || is_store_sub)
 /** @type {Function} */ setter(mutation ? getter() : value);
				return value;
			}
			return getter();
		});
	}
	var overridden = false;
	var d = ((flags & 1) !== 0 ? derived : derived_safe_equal)(() => {
		overridden = false;
		return getter();
	});
	if (bindable) get(d);
	var parent_effect = active_effect;
	return (function(value, mutation) {
		if (arguments.length > 0) {
			const new_value = mutation ? get(d) : runes && bindable ? proxy(value) : value;
			set(d, new_value);
			overridden = true;
			if (fallback_value !== void 0) fallback_value = new_value;
			return value;
		}
		if (is_destroying_effect && overridden || (parent_effect.f & 16384) !== 0) return d.v;
		return get(d);
	});
}
if (typeof HTMLElement === "function");
// src/recall.ts
/** The questions you asked in this conversation, newest first, once each. */
function askedBefore(messages) {
	const seen = /* @__PURE__ */ new Set();
	const out = [];
	for (let i = messages.length - 1; i >= 0; i--) {
		const m = messages[i];
		const text = m.text.trim();
		if (!m.fromUser || !text || seen.has(text)) continue;
		seen.add(text);
		out.push(m.text);
	}
	return out;
}
/**
* Where Up and Down are in the history. `step` returns the text to put in the field, or null when the key should do
* what it always does (move the caret): a field with your own words in it is never overwritten.
*/
var Recall = class {
	index = -1;
	reset() {
		this.index = -1;
	}
	/** Whether a recalled question is in the field unchanged; then Up and Down keep stepping wherever the caret is. */
	stepping(history, text) {
		return this.index >= 0 && text === history[this.index];
	}
	step(history, text, direction) {
		if (!history.length) return null;
		if (this.index === -1 ? text.trim() !== "" || direction === -1 : text !== history[this.index]) return null;
		const next = this.index + direction;
		if (next >= history.length) return null;
		this.index = next;
		return next < 0 ? "" : history[next];
	}
};
// node_modules/svelte/src/internal/disclose-version.js
if (typeof window !== "undefined") ((window.__svelte ??= {}).v ??= /* @__PURE__ */ new Set()).add("5");
// src/rich.ts
/** Inline Markdown in one line: `code`, **bold**, __bold__, *italic*, _italic_, ~~strike~~, [link](url). */
function inline$1(line, base) {
	const out = [];
	const pattern = /(`+)([^`]+?)\1|(\*\*|__)(?=\S)(.+?)(?<=\S)\3|(\*|_)(?=\S)(.+?)(?<=\S)\5(?![*_\w])|(~~)(?=\S)(.+?)(?<=\S)~~|\[([^\]\n]+)\]\(([^)\s]+)\)/g;
	let at = 0;
	const push = (text, styles) => {
		if (text) out.push({
			text,
			styles
		});
	};
	for (const m of line.matchAll(pattern)) {
		const start = m.index;
		push(line.slice(at, start), base);
		if (m[1]) {
			push(m[1], [
				...base,
				"code",
				"marker"
			]);
			push(m[2], [...base, "code"]);
			push(m[1], [
				...base,
				"code",
				"marker"
			]);
		} else if (m[3]) {
			push(m[3], [
				...base,
				"bold",
				"marker"
			]);
			for (const run of inline$1(m[4], [...base, "bold"])) out.push(run);
			push(m[3], [
				...base,
				"bold",
				"marker"
			]);
		} else if (m[5]) {
			push(m[5], [
				...base,
				"italic",
				"marker"
			]);
			for (const run of inline$1(m[6], [...base, "italic"])) out.push(run);
			push(m[5], [
				...base,
				"italic",
				"marker"
			]);
		} else if (m[7]) {
			push("~~", [
				...base,
				"strike",
				"marker"
			]);
			push(m[8], [...base, "strike"]);
			push("~~", [
				...base,
				"strike",
				"marker"
			]);
		} else {
			push("[", [
				...base,
				"link",
				"marker"
			]);
			push(m[9], [...base, "link"]);
			push(`](${m[10]})`, [
				...base,
				"link",
				"marker"
			]);
		}
		at = start + m[0].length;
	}
	push(line.slice(at), base);
	return out;
}
/** The whole text as runs, line by line: headings, list items, quotes and fenced code blocks, then inline styles. */
function richRuns(text) {
	const out = [];
	let fence = null;
	const lines = text.split("\n");
	lines.forEach((line, i) => {
		const end = i < lines.length - 1 ? "\n" : "";
		const fenceMark = /^\s*(```+|~~~+)/.exec(line);
		if (fence !== null || fenceMark) {
			const open = fence;
			if (open === null) fence = fenceMark[1];
			else if (fenceMark && fenceMark[1].startsWith(open[0]) && fenceMark[1].length >= open.length) fence = null;
			out.push({
				text: line + end,
				styles: fenceMark ? ["codeBlock", "marker"] : ["codeBlock"]
			});
			return;
		}
		const heading = /^(#{1,6} )(.*)$/.exec(line);
		const list = /^(\s*(?:[-*+]|\d+[.)]) (?:\[[ xX]\] )?)(.*)$/.exec(line);
		const quote = /^(\s*> ?)(.*)$/.exec(line);
		if (heading) {
			out.push({
				text: heading[1],
				styles: ["heading", "marker"]
			});
			out.push(...inline$1(heading[2], ["heading"]));
		} else if (list) {
			out.push({
				text: list[1],
				styles: ["list", "marker"]
			});
			out.push(...inline$1(list[2], []));
		} else if (quote) {
			out.push({
				text: quote[1],
				styles: ["quote", "marker"]
			});
			out.push(...inline$1(quote[2], ["quote"]));
		} else out.push(...inline$1(line, []));
		if (end) out.push({
			text: end,
			styles: []
		});
	});
	return out;
}
/** Whether the text has any Markdown worth drawing differently: plain text skips the layer. */
function hasMarkdown(text) {
	return richRuns(text).some((run) => run.styles.length > 0);
}
// src/Composer.svelte
var root$4 = /* @__PURE__ */ from_html(`<button type="button" class="thumb svelte-r7ttdz"><img alt="" class="svelte-r7ttdz"/></button>`);
var root_1$3 = /* @__PURE__ */ from_html(`<span class="file faint svelte-r7ttdz"> </span>`);
var root_2$3 = /* @__PURE__ */ from_html(`<button type="button" class="file svelte-r7ttdz"> <span class="faint svelte-r7ttdz"> </span></button>`);
var root_3$3 = /* @__PURE__ */ from_html(`<span class="slot svelte-r7ttdz" aria-hidden="true">+</span>`);
var root_4$3 = /* @__PURE__ */ from_html(`<div class="thumbs svelte-r7ttdz"><!> <!> <!> <!></div>`);
var root_5$3 = /* @__PURE__ */ from_html(`<p class="err svelte-r7ttdz"> </p>`);
var root_6$2 = /* @__PURE__ */ from_html(`<span> </span>`);
var root_7$2 = /* @__PURE__ */ from_html(`<div class="layer svelte-r7ttdz" aria-hidden="true"><!> </div>`);
var root_8$2 = /* @__PURE__ */ from_html(`<button type="button" class="icon svelte-r7ttdz"><svg viewBox="0 0 24 24" aria-hidden="true" class="svelte-r7ttdz"><path d="M12 5v14M5 12h14"></path></svg></button>`);
var root_9$1 = /* @__PURE__ */ from_html(`<button type="button" class="round queue svelte-r7ttdz"><svg viewBox="0 0 16 16" aria-hidden="true" class="svelte-r7ttdz"><path d="M2.5 4h11M2.5 8h11M2.5 12h6M11 10.5v4M9 12.5h4"></path></svg></button>`);
var root_10$1 = /* @__PURE__ */ from_html(`<button type="button" class="round stop svelte-r7ttdz"><svg viewBox="0 0 16 16" aria-hidden="true" class="svelte-r7ttdz"><rect x="4.5" y="4.5" width="7" height="7" rx="1.5"></rect></svg></button>`);
var root_11$1 = /* @__PURE__ */ from_html(`<button type="button" class="round send svelte-r7ttdz"><svg viewBox="0 0 16 16" aria-hidden="true" class="svelte-r7ttdz"><path d="M8 13V3.5M3.75 7.5 8 3.25l4.25 4.25"></path></svg></button>`);
var root_12$1 = /* @__PURE__ */ from_html(`<div role="group"><!> <div class="box svelte-r7ttdz"><!> <!> <div><!> <textarea rows="1" class="svelte-r7ttdz"></textarea></div> <div class="row svelte-r7ttdz"><input class="file-input svelte-r7ttdz" type="file" multiple=""/> <!> <!> <span class="grow svelte-r7ttdz"></span> <!> <!> <!></div></div> <!></div>`);
var $$css$5 = {
	hash: "svelte-r7ttdz",
	code: "\n  /* Every color comes from the surface (`--nc-*`); the fallbacks are Nook's own light theme. */.nook-composer.svelte-r7ttdz {display:flex;flex-direction:column;gap:8px;min-width:0;}.box.svelte-r7ttdz {display:flex;flex-direction:column;padding:var(--nc-pad, 10px 12px);border:1px solid var(--nc-line, #e4e4e7);border-radius:var(--nc-radius, 16px);background:var(--nc-surface, #ffffff);box-shadow:var(--nc-shadow, none);transition:background-color 0.2s ease, border-color 0.2s ease;}.box.svelte-r7ttdz:focus-within {background:var(--nc-surface-focus, var(--nc-surface, #ffffff));border-color:var(--nc-line-focus, #d4d4d8);}.dragging.svelte-r7ttdz .box:where(.svelte-r7ttdz) {outline:2px dashed var(--nc-accent, #1e1e22);outline-offset:-4px;}.compact.svelte-r7ttdz .box:where(.svelte-r7ttdz) {padding:6px 8px;}textarea.svelte-r7ttdz {width:100%;box-sizing:border-box;min-height:var(--nc-field-min, 20px);max-height:160px;field-sizing:content;resize:none;margin:0;padding:var(--nc-field-pad, 2px 2px 0);border:0;outline:none;box-shadow:none;background:transparent;color:var(--nc-text, #27272a);font:inherit;line-height:var(--nc-line-height, 1.25);}textarea.svelte-r7ttdz::placeholder {color:var(--nc-faint, #62626c);}\n  /* The rich composer: the layer and the field share one box, font and wrapping, so every character sits in the same\n     place; widths never change (bold is drawn with a shadow, code with a tint), so the caret stays on its character. */.field.svelte-r7ttdz {position:relative;display:flex;min-width:0;}.layer.svelte-r7ttdz {position:absolute;inset:0;overflow:hidden;padding:var(--nc-field-pad, 2px 2px 0);white-space:pre-wrap;overflow-wrap:break-word;color:var(--nc-text, #27272a);font:inherit;line-height:var(--nc-line-height, 1.25);pointer-events:none;}.styled.svelte-r7ttdz textarea:where(.svelte-r7ttdz) {color:transparent;caret-color:var(--nc-text, #27272a);position:relative;}.styled.svelte-r7ttdz textarea:where(.svelte-r7ttdz)::selection {color:transparent;}.layer.svelte-r7ttdz .marker:where(.svelte-r7ttdz) {color:var(--nc-faint, #62626c);}.layer.svelte-r7ttdz .bold:where(.svelte-r7ttdz), .layer.svelte-r7ttdz .heading:where(.svelte-r7ttdz) {text-shadow:0.35px 0 0 currentColor, -0.35px 0 0 currentColor;}.layer.svelte-r7ttdz .heading:where(.svelte-r7ttdz) {color:var(--nc-text-strong, var(--nc-text, #27272a));}.layer.svelte-r7ttdz .italic:where(.svelte-r7ttdz) {color:var(--nc-text-soft, color-mix(in srgb, var(--nc-text, #27272a) 82%, transparent));}.layer.svelte-r7ttdz .strike:where(.svelte-r7ttdz) {text-decoration:line-through;}.layer.svelte-r7ttdz .code:where(.svelte-r7ttdz), .layer.svelte-r7ttdz .codeBlock:where(.svelte-r7ttdz) {background:var(--nc-code, color-mix(in srgb, var(--nc-text, #27272a) 10%, transparent));border-radius:3px;}.layer.svelte-r7ttdz .link:where(.svelte-r7ttdz) {color:var(--nc-accent, #1e1e22);text-decoration:underline;text-decoration-color:color-mix(in srgb, currentColor 40%, transparent);}.layer.svelte-r7ttdz .list.marker:where(.svelte-r7ttdz), .layer.svelte-r7ttdz .quote.marker:where(.svelte-r7ttdz) {color:var(--nc-accent, #1e1e22);}.layer.svelte-r7ttdz .quote:where(.svelte-r7ttdz) {color:var(--nc-faint, #62626c);}textarea.svelte-r7ttdz:focus-visible {box-shadow:none;outline:none;}textarea.svelte-r7ttdz:disabled {cursor:default;}.row.svelte-r7ttdz {display:flex;align-items:center;gap:var(--nc-row-gap, 6px);margin:var(--nc-row-margin, 6px 0 0 -4px);min-width:0;min-height:32px;}\n  /* Match macOS `ComposerDictationButton` (30pt) inside the 32pt control row so the composer stays 84pt tall. */.row.svelte-r7ttdz button.mic {width:30px;height:30px;}.grow.svelte-r7ttdz {flex:1;}.file-input.svelte-r7ttdz {display:none;}button.icon.svelte-r7ttdz, button.round.svelte-r7ttdz {flex-shrink:0;display:grid;place-items:center;margin:0;padding:0;border:0;cursor:pointer;}button.icon.svelte-r7ttdz {width:32px;height:32px;border-radius:var(--nc-control-radius, 8px);background:transparent;color:var(--nc-faint, #62626c);}button.icon.svelte-r7ttdz:hover:not(:disabled) {background:var(--nc-hover, #f4f4f5);color:var(--nc-text, #27272a);}button.icon.svelte-r7ttdz svg:where(.svelte-r7ttdz) {width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:1.65;stroke-linecap:round;stroke-linejoin:round;}button.round.svelte-r7ttdz {width:32px;height:32px;border-radius:999px;}button.round.svelte-r7ttdz svg:where(.svelte-r7ttdz) {width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:1.75;stroke-linecap:round;stroke-linejoin:round;}button.send.svelte-r7ttdz, button.queue.svelte-r7ttdz {background:var(--nc-accent, #1e1e22);color:var(--nc-on-accent, #ffffff);}button.send.svelte-r7ttdz:hover:not(:disabled), button.queue.svelte-r7ttdz:hover:not(:disabled) {background:var(--nc-accent-hover, var(--nc-accent, #3b3b3f));}button.send.svelte-r7ttdz:disabled {background:var(--nc-disabled, #e4e4e7);color:var(--nc-faint, #62626c);cursor:default;}button.stop.svelte-r7ttdz {background:var(--nc-stop, #18181b);color:var(--nc-on-stop, #fcfcfc);}button.stop.svelte-r7ttdz svg:where(.svelte-r7ttdz) {fill:currentColor;stroke:none;}button.svelte-r7ttdz:disabled {cursor:default;opacity:0.6;}button.send.svelte-r7ttdz:disabled {opacity:1;}button.svelte-r7ttdz:focus-visible {outline:2px solid var(--nc-accent, #1e1e22);outline-offset:2px;}.thumbs.svelte-r7ttdz {display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin-bottom:8px;}.thumb.svelte-r7ttdz {width:46px;height:46px;padding:0;overflow:hidden;border:1px solid var(--nc-line, #e4e4e7);border-radius:8px;background:none;cursor:pointer;}.thumb.svelte-r7ttdz img:where(.svelte-r7ttdz) {width:100%;height:100%;object-fit:cover;display:block;}.slot.svelte-r7ttdz {display:grid;place-items:center;width:46px;height:46px;box-sizing:border-box;border:1.5px dashed var(--nc-accent, #1e1e22);border-radius:8px;color:var(--nc-accent, #1e1e22);background:color-mix(in srgb, var(--nc-accent, #1e1e22) 12%, transparent);font-size:18px;pointer-events:none;}.file.svelte-r7ttdz {max-width:100%;overflow-wrap:anywhere;text-align:left;font:inherit;font-size:12px;padding:4px 10px;border:1px solid var(--nc-line, #e4e4e7);border-radius:8px;background:none;color:var(--nc-text, #27272a);}.faint.svelte-r7ttdz {color:var(--nc-faint, #62626c);}.err.svelte-r7ttdz {color:var(--nc-error, #c10007);font-size:12px;margin:0 0 6px;}"
};
function Composer($$anchor, $$props) {
	push($$props, true);
	append_styles$1($$anchor, $$css$5);
	let draft = prop($$props, "draft", 7), busy = prop($$props, "busy", 3, false), queues = prop($$props, "queues", 3, false), disabled = prop($$props, "disabled", 3, false), history = prop($$props, "history", 19, () => []), historyKey = prop($$props, "historyKey", 3, null), escapeStops = prop($$props, "escapeStops", 3, false), compact = prop($$props, "compact", 3, false), autofocus = prop($$props, "autofocus", 3, false), rich = prop($$props, "rich", 3, false);
	/** Stops Nook's answer. Without it, a busy composer only waits. */
	/** Nook is answering: send waits (or becomes stop when `onstop` is given). */
	/** While busy, Return and the queue button still send: the message waits in line for after this answer. */
	/** Nothing can be sent at all (not connected): the field is read-only. */
	/** Your earlier questions in this conversation, newest first (`askedBefore`). */
	/** The conversation the history belongs to: a new one starts Up from the newest question again. */
	/** Escape stops the answer (in a window; in a bar Escape closes the bar). */
	/** Replaces the attach button with a menu of its own (the Mac's `ComposerMoreMenu`); `pickFile` opens the file picker. */
	/** Markdown shows its style as you type (the Mac's rich composer); what is sent stays plain Markdown. */
	let field = /* @__PURE__ */ state(void 0);
	let layer = /* @__PURE__ */ state(void 0);
	const styled = /* @__PURE__ */ user_derived(() => rich() && hasMarkdown(draft().text));
	const runs = /* @__PURE__ */ user_derived(() => get(styled) ? richRuns(draft().text) : []);
	let fileInput = /* @__PURE__ */ state(void 0);
	let dragging = /* @__PURE__ */ state(false);
	const recall = new Recall();
	let recallFor = null;
	user_effect(() => {
		if (historyKey() !== recallFor) {
			recallFor = historyKey();
			recall.reset();
		}
	});
	user_effect(() => {
		if (autofocus()) get(field)?.focus();
	});
	function focus() {
		get(field)?.focus();
	}
	const stoppable = /* @__PURE__ */ user_derived(() => busy() && !!$$props.onstop);
	const canSend = /* @__PURE__ */ user_derived(() => !draft().empty && (!busy() || queues()) && !disabled() && !draft().reading);
	async function send() {
		if (!get(canSend)) return;
		const message = {
			text: draft().text.trim(),
			images: draft().images.map(({ mediaType, base64 }) => ({
				mediaType,
				base64
			})),
			attachment: draft().attachment
		};
		draft().clear();
		recall.reset();
		await $$props.onsend(message);
	}
	function key(e) {
		if (e.isComposing || !get(field)) return;
		if (e.key === "Enter" && !e.shiftKey && !e.ctrlKey && !e.metaKey) {
			e.preventDefault();
			send();
		} else if ((e.key === "ArrowUp" || e.key === "ArrowDown") && !e.shiftKey && !e.altKey && !e.ctrlKey && !e.metaKey) {
			const up = e.key === "ArrowUp";
			const atStart = get(field).selectionStart === 0 && get(field).selectionEnd === 0;
			const atEnd = get(field).selectionStart === draft().text.length;
			const stepping = recall.stepping(history(), draft().text);
			if (!(up ? atStart || !draft().text || stepping : atEnd || stepping)) return;
			const text = recall.step(history(), draft().text, up ? 1 : -1);
			if (text === null) return;
			e.preventDefault();
			draft().text = text;
			queueMicrotask(() => get(field)?.setSelectionRange(text.length, text.length));
		} else if (e.key === "Escape" && escapeStops() && get(stoppable)) {
			e.preventDefault();
			$$props.onstop?.();
		}
	}
	function pickFile() {
		draft().picking = true;
		get(fileInput)?.click();
	}
	function picked() {
		draft().picking = false;
		if (get(fileInput)?.files) draft().addFiles(get(fileInput).files);
		if (get(fileInput)) get(fileInput).value = "";
	}
	function paste(e) {
		const files = Array.from(e.clipboardData?.files ?? []);
		if (!files.length) return;
		e.preventDefault();
		draft().addFiles(files);
	}
	const accept = /* @__PURE__ */ user_derived(() => draft().readsDocuments ? "image/*,.txt,.md,.csv,.json,.pdf,.docx,.odt,.pptx,.zip" : "image/*");
	const placeholder = /* @__PURE__ */ user_derived(() => draft().attachment && $$props.texts.placeholderFor ? $$props.texts.placeholderFor(draft().attachment.name) : $$props.texts.placeholder);
	var $$exports = { focus };
	var div = root_12$1();
	let classes;
	var node = child(div);
	snippet(node, () => $$props.top ?? noop);
	var div_1 = sibling(node, 2);
	var node_1 = child(div_1);
	var consequent_3 = ($$anchor) => {
		var div_2 = root_4$3();
		var node_2 = child(div_2);
		each(node_2, 19, () => draft().images, (img) => img.url, ($$anchor, img, i) => {
			var button = root$4();
			var img_1 = only_child(button);
			template_effect(() => {
				set_attribute(button, "title", $$props.texts.removeImage);
				set_attribute(button, "aria-label", $$props.texts.removeImage);
				set_attribute(img_1, "src", get(img).url);
			});
			delegated("click", button, () => draft().removeImage(get(i)));
			append($$anchor, button);
		});
		var node_3 = sibling(node_2, 2);
		var consequent = ($$anchor) => {
			var span = root_1$3();
			var text_1 = only_child(span, true);
			template_effect(() => set_text(text_1, $$props.texts.reading));
			append($$anchor, span);
		};
		if_block(node_3, ($$render) => {
			if (draft().reading) $$render(consequent);
		});
		var node_4 = sibling(node_3, 2);
		var consequent_1 = ($$anchor) => {
			var button_1 = root_2$3();
			var text_2 = child(button_1);
			var text_3 = only_child(sibling(text_2));
			reset(button_1);
			template_effect(($0) => {
				set_attribute(button_1, "title", $$props.texts.removeFile);
				set_text(text_2, `${draft().attachment.name ?? ""} `);
				set_text(text_3, `· ${$0 ?? ""} ${$$props.texts.characters ?? ""} ×`);
			}, [() => draft().attachment.text.length.toLocaleString($$props.locale)]);
			delegated("click", button_1, () => draft().attachment = null);
			append($$anchor, button_1);
		};
		if_block(node_4, ($$render) => {
			if (draft().attachment) $$render(consequent_1);
		});
		var node_5 = sibling(node_4, 2);
		var consequent_2 = ($$anchor) => {
			append($$anchor, root_3$3());
		};
		if_block(node_5, ($$render) => {
			if (get(dragging)) $$render(consequent_2);
		});
		reset(div_2);
		append($$anchor, div_2);
	};
	if_block(node_1, ($$render) => {
		if (draft().images.length || draft().attachment || draft().reading || get(dragging)) $$render(consequent_3);
	});
	var node_6 = sibling(node_1, 2);
	var consequent_4 = ($$anchor) => {
		var p = root_5$3();
		var text_4 = only_child(p, true);
		template_effect(() => set_text(text_4, draft().fileError));
		append($$anchor, p);
	};
	if_block(node_6, ($$render) => {
		if (draft().fileError) $$render(consequent_4);
	});
	var div_3 = sibling(node_6, 2);
	let classes_1;
	var node_7 = child(div_3);
	var consequent_5 = ($$anchor) => {
		var div_4 = root_7$2();
		var node_8 = child(div_4);
		each(node_8, 17, () => get(runs), index, ($$anchor, run) => {
			var span_3 = root_6$2();
			var text_5 = only_child(span_3, true);
			template_effect(($0) => {
				set_class(span_3, 1, $0, "svelte-r7ttdz");
				set_text(text_5, get(run).text);
			}, [() => clsx(get(run).styles.join(" "))]);
			append($$anchor, span_3);
		});
		var text_6 = sibling(node_8, 1, true);
		text_6.nodeValue = "​";
		reset(div_4);
		bind_this(div_4, ($$value) => set(layer, $$value), () => get(layer));
		append($$anchor, div_4);
	};
	if_block(node_7, ($$render) => {
		if (get(styled)) $$render(consequent_5);
	});
	var textarea = sibling(node_7, 2);
	remove_textarea_child(textarea);
	bind_this(textarea, ($$value) => set(field, $$value), () => get(field));
	reset(div_3);
	var div_5 = sibling(div_3, 2);
	var input = child(div_5);
	bind_this(input, ($$value) => set(fileInput, $$value), () => get(fileInput));
	var node_9 = sibling(input, 2);
	var consequent_6 = ($$anchor) => {
		var fragment = comment();
		snippet(first_child(fragment), () => $$props.plus, () => ({
			pickFile,
			disabled: disabled() || draft().reading
		}));
		append($$anchor, fragment);
	};
	var alternate = ($$anchor) => {
		var button_2 = root_8$2();
		template_effect(() => {
			set_attribute(button_2, "title", $$props.texts.attach);
			set_attribute(button_2, "aria-label", $$props.texts.attach);
			button_2.disabled = disabled() || draft().reading;
		});
		delegated("click", button_2, pickFile);
		append($$anchor, button_2);
	};
	if_block(node_9, ($$render) => {
		if ($$props.plus) $$render(consequent_6);
		else $$render(alternate, -1);
	});
	var node_11 = sibling(node_9, 2);
	snippet(node_11, () => $$props.controls ?? noop);
	var node_12 = sibling(node_11, 4);
	snippet(node_12, () => $$props.extras ?? noop);
	var node_13 = sibling(node_12, 2);
	var consequent_7 = ($$anchor) => {
		var button_3 = root_9$1();
		template_effect(() => {
			button_3.disabled = !get(canSend);
			set_attribute(button_3, "title", $$props.texts.queue);
			set_attribute(button_3, "aria-label", $$props.texts.queue);
		});
		delegated("click", button_3, send);
		append($$anchor, button_3);
	};
	if_block(node_13, ($$render) => {
		if (get(stoppable) && queues() && !draft().empty) $$render(consequent_7);
	});
	var node_14 = sibling(node_13, 2);
	var consequent_8 = ($$anchor) => {
		var button_4 = root_10$1();
		template_effect(() => {
			set_attribute(button_4, "title", $$props.texts.stop);
			set_attribute(button_4, "aria-label", $$props.texts.stop);
		});
		delegated("click", button_4, () => $$props.onstop?.());
		append($$anchor, button_4);
	};
	var alternate_1 = ($$anchor) => {
		var button_5 = root_11$1();
		template_effect(() => {
			button_5.disabled = !get(canSend);
			set_attribute(button_5, "title", $$props.texts.send);
			set_attribute(button_5, "aria-label", $$props.texts.send);
		});
		delegated("click", button_5, send);
		append($$anchor, button_5);
	};
	if_block(node_14, ($$render) => {
		if (get(stoppable)) $$render(consequent_8);
		else $$render(alternate_1, -1);
	});
	reset(div_5);
	reset(div_1);
	snippet(sibling(div_1, 2), () => $$props.under ?? noop);
	reset(div);
	template_effect(() => {
		classes = set_class(div, 1, "nook-composer svelte-r7ttdz", null, classes, {
			compact: compact(),
			dragging: get(dragging)
		});
		classes_1 = set_class(div_3, 1, "field svelte-r7ttdz", null, classes_1, { styled: get(styled) });
		textarea.disabled = disabled();
		set_attribute(textarea, "aria-label", $$props.texts.field);
		set_attribute(textarea, "placeholder", get(placeholder));
		set_attribute(input, "accept", get(accept));
		set_attribute(input, "aria-label", $$props.texts.attach);
	});
	event("dragover", div, (e) => {
		if (disabled()) return;
		e.preventDefault();
		set(dragging, e.dataTransfer?.types.includes("Files") ?? false, true);
	});
	event("dragleave", div, (e) => {
		if (!e.currentTarget.contains(e.relatedTarget)) set(dragging, false);
	});
	event("drop", div, (e) => {
		e.preventDefault();
		set(dragging, false);
		if (!disabled() && e.dataTransfer?.files) draft().addFiles(e.dataTransfer.files);
	});
	delegated("keydown", textarea, key);
	event("paste", textarea, paste);
	delegated("input", textarea, () => recall.reset());
	event("scroll", textarea, () => {
		if (get(layer) && get(field)) get(layer).scrollTop = get(field).scrollTop;
	});
	bind_value(textarea, () => draft().text, ($$value) => draft().text = $$value);
	delegated("change", input, picked);
	event("cancel", input, () => draft().picking = false);
	append($$anchor, div);
	return pop($$exports);
}
delegate([
	"click",
	"keydown",
	"input",
	"change"
]);
// src/brandLogos.ts
/** Each brand's paths on a 24×24 grid, filled even-odd. */
var brandPaths = {
	"claude": ["M4.709 15.955L9.429 13.308L9.509 13.078L9.429 12.95L9.2 12.95L8.41 12.902L5.712 12.829L3.373 12.732L1.107 12.61L0.536 12.489L0 11.784L0.055 11.432L0.535 11.111L1.221 11.171L2.741 11.274L5.019 11.432L6.671 11.529L9.12 11.784L9.509 11.784L9.564 11.627L9.43 11.529L9.327 11.432L6.969 9.836L4.417 8.148L3.081 7.176L2.357 6.685L1.993 6.223L1.835 5.215L2.491 4.493L3.372 4.553L3.597 4.614L4.49 5.3L6.398 6.776L8.889 8.609L9.254 8.913L9.399 8.81L9.418 8.737L9.254 8.463L7.899 6.017L6.453 3.527L5.809 2.495L5.639 1.876C5.574 1.638 5.539 1.393 5.535 1.147L6.283 0.134L6.696 0L7.692 0.134L8.112 0.498L8.732 1.912L9.734 4.141L11.289 7.171L11.745 8.069L11.988 8.901L12.079 9.156L12.237 9.156L12.237 9.01L12.365 7.304L12.602 5.209L12.832 2.514L12.912 1.754L13.288 0.844L14.035 0.352L14.619 0.632L15.099 1.317L15.032 1.761L14.746 3.612L14.187 6.515L13.823 8.457L14.035 8.457L14.278 8.215L15.263 6.909L16.915 4.845L17.645 4.025L18.495 3.121L19.042 2.69L20.075 2.69L20.835 3.819L20.495 4.985L19.431 6.332L18.55 7.474L17.286 9.174L16.496 10.534L16.569 10.644L16.757 10.624L19.613 10.018L21.156 9.738L22.997 9.423L23.83 9.811L23.921 10.206L23.593 11.013L21.624 11.499L19.315 11.961L15.876 12.774L15.834 12.804L15.883 12.865L17.432 13.011L18.094 13.047L19.716 13.047L22.736 13.272L23.526 13.794L24 14.432L23.921 14.917L22.706 15.537L21.066 15.148L17.237 14.238L15.925 13.909L15.743 13.909L15.743 14.019L16.836 15.087L18.842 16.897L21.351 19.227L21.478 19.805L21.156 20.26L20.816 20.211L18.611 18.554L17.76 17.807L15.834 16.187L15.706 16.187L15.706 16.357L16.15 17.006L18.495 20.527L18.617 21.607L18.447 21.96L17.839 22.173L17.171 22.051L15.797 20.126L14.382 17.959L13.239 16.016L13.099 16.096L12.425 23.35L12.109 23.72L11.38 24L10.773 23.539L10.451 22.792L10.773 21.316L11.162 19.392L11.477 17.862L11.763 15.962L11.933 15.33L11.921 15.288L11.781 15.306L10.347 17.273L8.167 20.218L6.441 22.063L6.027 22.227L5.31 21.857L5.377 21.195L5.778 20.606L8.166 17.57L9.606 15.688L10.536 14.602L10.53 14.444L10.475 14.444L4.132 18.56L3.002 18.706L2.515 18.25L2.576 17.504L2.807 17.261L4.715 15.949L4.709 15.955Z"],
	"openai": ["M9.205 8.658L9.205 6.398C9.205 6.208 9.277 6.065 9.443 5.97L13.986 3.354C14.605 2.997 15.342 2.831 16.103 2.831C18.957 2.831 20.765 5.043 20.765 7.397C20.765 7.564 20.765 7.754 20.741 7.944L16.031 5.185C15.946 5.131 15.852 5.093 15.753 5.075C15.654 5.056 15.552 5.056 15.453 5.075C15.354 5.093 15.26 5.131 15.175 5.185L9.205 8.658ZM19.814 17.458L19.814 12.06C19.814 11.727 19.671 11.49 19.385 11.323L13.415 7.85L15.365 6.732C15.412 6.701 15.464 6.68 15.52 6.669C15.575 6.658 15.631 6.658 15.686 6.669C15.742 6.68 15.794 6.701 15.841 6.732L20.384 9.349C21.693 10.109 22.573 11.727 22.573 13.297C22.573 15.105 21.503 16.77 19.813 17.46ZM7.802 12.703L5.852 11.561C5.685 11.466 5.613 11.323 5.613 11.133L5.613 5.899C5.613 3.354 7.563 1.427 10.204 1.427C11.204 1.427 12.131 1.76 12.916 2.355L8.23 5.067C7.945 5.233 7.802 5.471 7.802 5.804L7.802 12.702ZM12 15.128L9.205 13.558L9.205 10.228L12 8.658L14.795 10.228L14.795 13.558L12 15.128ZM13.796 22.358C12.796 22.358 11.869 22.026 11.084 21.431L15.77 18.719C16.055 18.553 16.198 18.315 16.198 17.982L16.198 11.084L18.172 12.226C18.339 12.321 18.41 12.464 18.41 12.654L18.41 17.887C18.41 20.432 16.436 22.359 13.796 22.359ZM8.159 17.055L3.615 14.438C2.307 13.677 1.427 12.06 1.427 10.49C1.425 9.898 1.54 9.311 1.766 8.763C1.993 8.216 2.325 7.719 2.744 7.301C3.164 6.882 3.662 6.552 4.21 6.327L4.21 11.75C4.21 12.083 4.353 12.321 4.638 12.488L10.585 15.937L8.635 17.055C8.588 17.086 8.536 17.107 8.48 17.118C8.425 17.129 8.369 17.129 8.314 17.118C8.258 17.107 8.206 17.086 8.159 17.055ZM7.897 20.955C5.209 20.955 3.235 18.934 3.235 16.436C3.235 16.246 3.259 16.056 3.282 15.866L7.968 18.576C8.254 18.743 8.539 18.743 8.824 18.576L14.794 15.128L14.794 17.388C14.794 17.578 14.724 17.721 14.557 17.816L10.014 20.432C9.395 20.789 8.658 20.955 7.897 20.955ZM13.796 23.785C14.705 23.785 15.601 23.577 16.417 23.176C17.233 22.776 17.946 22.194 18.502 21.475C19.057 20.756 19.441 19.919 19.623 19.029C22.287 18.339 24 15.84 24 13.296C24 11.631 23.287 10.014 22.002 8.848C22.121 8.348 22.192 7.849 22.192 7.35C22.192 3.949 19.433 1.403 16.246 1.403C15.604 1.403 14.986 1.498 14.366 1.713C13.816 1.172 13.167 0.743 12.453 0.449C11.74 0.155 10.976 0.003 10.205 0C9.296 0 8.399 0.208 7.584 0.609C6.768 1.009 6.055 1.591 5.499 2.311C4.943 3.03 4.56 3.867 4.378 4.757C1.713 5.447 0 7.945 0 10.49C0 12.156 0.713 13.773 1.998 14.938C1.879 15.438 1.808 15.938 1.808 16.437C1.808 19.838 4.567 22.383 7.754 22.383C8.396 22.383 9.014 22.288 9.634 22.074C10.184 22.615 10.834 23.045 11.547 23.338C12.261 23.632 13.024 23.784 13.796 23.787Z"],
	"gemini": ["M20.616 10.835C18.955 10.128 17.444 9.109 16.166 7.834C15.28 6.946 14.516 5.944 13.895 4.854C13.274 3.765 12.801 2.597 12.488 1.382C12.47 1.31 12.436 1.243 12.389 1.186C12.341 1.129 12.282 1.083 12.215 1.051C12.148 1.019 12.075 1.003 12 1.003C11.926 1.003 11.853 1.019 11.786 1.051C11.719 1.083 11.66 1.129 11.612 1.186C11.565 1.243 11.531 1.31 11.513 1.382C11.2 2.597 10.726 3.764 10.105 4.854C9.484 5.944 8.72 6.946 7.834 7.834C6.556 9.109 5.045 10.128 3.384 10.835C2.734 11.115 2.066 11.34 1.382 11.513C1.31 11.531 1.242 11.564 1.184 11.611C1.127 11.659 1.08 11.718 1.048 11.785C1.016 11.852 1 11.926 1 12.001C1 12.075 1.016 12.149 1.048 12.216C1.08 12.283 1.127 12.342 1.184 12.39C1.242 12.437 1.31 12.47 1.382 12.488C2.066 12.66 2.732 12.885 3.384 13.165C5.045 13.872 6.556 14.891 7.834 16.166C8.72 17.054 9.484 18.056 10.106 19.146C10.727 20.236 11.2 21.404 11.513 22.619C11.531 22.691 11.564 22.759 11.611 22.817C11.659 22.874 11.718 22.921 11.785 22.953C11.852 22.985 11.926 23.001 12 23.001C12.075 23.001 12.149 22.985 12.216 22.953C12.283 22.921 12.342 22.874 12.39 22.817C12.437 22.759 12.47 22.691 12.488 22.619C12.66 21.934 12.885 21.268 13.165 20.616C13.872 18.955 14.891 17.444 16.166 16.166C17.054 15.28 18.056 14.516 19.146 13.895C20.236 13.274 21.404 12.801 22.619 12.488C22.691 12.47 22.758 12.436 22.815 12.389C22.872 12.341 22.918 12.282 22.95 12.215C22.982 12.148 22.998 12.075 22.998 12C22.998 11.926 22.982 11.853 22.95 11.786C22.918 11.719 22.872 11.66 22.815 11.612C22.758 11.565 22.691 11.531 22.619 11.513C21.934 11.341 21.265 11.114 20.616 10.835Z"],
	"mistral": ["M3.428 3.4L6.857 3.4L6.857 6.828L10.286 6.828L10.286 10.257L10.284 10.257L13.715 10.257L13.715 6.828L17.142 6.828L17.142 3.4L20.572 3.4L20.572 17.114L24 17.114L24 20.543L13.714 20.543L13.714 17.115L10.286 17.115L10.286 13.686L6.856 13.686L6.856 17.114L10.286 17.114L10.286 20.543L0 20.543L0 17.114L3.428 17.114L3.428 3.4ZM13.714 17.115L17.142 17.115L17.142 13.686L13.715 13.686L13.715 17.115Z"],
	"ollama": ["M7.905 1.09C8.121 1.175 8.316 1.315 8.493 1.5C8.788 1.806 9.037 2.244 9.227 2.763C9.418 3.285 9.542 3.863 9.589 4.443C10.219 4.087 10.917 3.87 11.638 3.807L11.689 3.803C12.559 3.733 13.419 3.89 14.169 4.277C14.27 4.33 14.369 4.387 14.466 4.447C14.516 3.878 14.638 3.313 14.826 2.803C15.016 2.283 15.265 1.846 15.559 1.539C15.723 1.361 15.924 1.221 16.148 1.129C16.405 1.029 16.678 1.011 16.944 1.087C17.345 1.201 17.689 1.455 17.96 1.824C18.208 2.161 18.394 2.593 18.521 3.111C18.751 4.045 18.791 5.274 18.636 6.756L18.689 6.796L18.715 6.815C19.472 7.391 19.999 8.212 20.278 9.165C20.713 10.652 20.494 12.32 19.744 13.253L19.726 13.274L19.728 13.277C20.145 14.039 20.398 14.844 20.452 15.677L20.454 15.707C20.518 16.772 20.254 17.844 19.64 18.897L19.633 18.907L19.643 18.931C20.115 20.088 20.263 21.253 20.081 22.417L20.075 22.456C20.056 22.569 20.008 22.674 19.936 22.762C19.864 22.851 19.769 22.918 19.663 22.959C19.556 22.999 19.441 23.01 19.328 22.992C19.244 22.979 19.163 22.949 19.09 22.905C19.017 22.86 18.954 22.802 18.904 22.733C18.854 22.664 18.818 22.586 18.798 22.503C18.778 22.42 18.775 22.334 18.788 22.25C18.955 21.217 18.798 20.181 18.308 19.127C18.262 19.029 18.242 18.921 18.249 18.813C18.256 18.706 18.29 18.601 18.348 18.51L18.352 18.504C18.956 17.58 19.206 16.674 19.152 15.784C19.106 15.005 18.827 14.24 18.352 13.511C18.291 13.417 18.255 13.309 18.249 13.197C18.242 13.085 18.265 12.974 18.314 12.874C18.364 12.773 18.439 12.688 18.532 12.625L18.541 12.619C18.784 12.46 19.008 12.054 19.121 11.499C19.246 10.843 19.213 10.166 19.026 9.525C18.821 8.825 18.446 8.241 17.921 7.842C17.326 7.388 16.538 7.169 15.541 7.232C15.454 7.238 15.368 7.226 15.286 7.198C15.204 7.169 15.128 7.125 15.063 7.067C14.999 7.009 14.946 6.939 14.909 6.861C14.595 6.196 14.137 5.72 13.566 5.425C13.293 5.289 13.003 5.191 12.703 5.135C12.404 5.079 12.098 5.065 11.794 5.093C10.549 5.192 9.451 5.894 9.124 6.779C9.093 6.862 9.046 6.937 8.985 7.001C8.925 7.065 8.851 7.116 8.77 7.151C8.689 7.186 8.602 7.204 8.514 7.204C7.447 7.206 6.621 7.456 6.017 7.907C5.495 8.297 5.139 8.842 4.951 9.495C4.781 10.11 4.758 10.756 4.883 11.381C4.995 11.939 5.214 12.401 5.465 12.65L5.473 12.657C5.685 12.864 5.73 13.187 5.582 13.442C5.222 14.064 4.953 14.991 4.909 15.882C4.859 16.9 5.095 17.784 5.628 18.418L5.644 18.437C5.697 18.499 5.738 18.571 5.765 18.649C5.791 18.726 5.803 18.808 5.798 18.89C5.794 18.972 5.774 19.053 5.739 19.127C5.163 20.363 4.986 21.379 5.177 22.179C5.2 22.289 5.194 22.403 5.159 22.51C5.125 22.617 5.063 22.714 4.981 22.79C4.898 22.866 4.797 22.92 4.688 22.946C4.578 22.971 4.464 22.968 4.356 22.937C4.248 22.905 4.15 22.846 4.071 22.766C3.993 22.685 3.937 22.586 3.908 22.477C3.665 21.459 3.83 20.293 4.381 18.979L4.395 18.944L4.387 18.932C4.116 18.532 3.914 18.09 3.789 17.623L3.784 17.604C3.632 17.022 3.572 16.42 3.607 15.819C3.651 14.909 3.885 13.977 4.229 13.229L4.241 13.203L4.239 13.201C3.946 12.783 3.729 12.248 3.609 11.656L3.604 11.632C3.439 10.806 3.471 9.953 3.697 9.142C3.959 8.227 4.474 7.441 5.233 6.873C5.293 6.828 5.356 6.783 5.419 6.741C5.26 5.248 5.3 4.011 5.531 3.071C5.658 2.553 5.845 2.121 6.093 1.784C6.363 1.416 6.707 1.162 7.108 1.047C7.374 0.971 7.648 0.988 7.905 1.089ZM12.021 10.18C12.957 10.18 13.821 10.493 14.467 11.035C15.097 11.562 15.472 12.27 15.472 12.975C15.472 13.863 15.066 14.555 14.339 14.997C13.719 15.372 12.888 15.554 11.936 15.554C10.927 15.554 10.065 15.295 9.443 14.82C8.826 14.35 8.48 13.69 8.48 12.975C8.48 12.268 8.878 11.558 9.536 11.029C10.204 10.492 11.086 10.18 12.021 10.18ZM12.021 11.076C11.677 11.073 11.334 11.128 11.008 11.239C10.682 11.349 10.376 11.514 10.105 11.726C9.644 12.096 9.383 12.561 9.383 12.976C9.383 13.404 9.593 13.805 9.993 14.11C10.448 14.457 11.117 14.658 11.936 14.658C12.735 14.658 13.409 14.511 13.868 14.232C14.331 13.952 14.568 13.546 14.568 12.975C14.568 12.552 14.322 12.085 13.885 11.719C13.401 11.314 12.745 11.076 12.021 11.076ZM12.683 12.286L12.687 12.29C12.807 12.441 12.782 12.66 12.631 12.78L12.339 13.01L12.339 13.456C12.339 13.522 12.321 13.586 12.288 13.643C12.255 13.7 12.207 13.747 12.15 13.779C12.093 13.812 12.029 13.829 11.963 13.829C11.897 13.829 11.833 13.812 11.776 13.779C11.719 13.747 11.671 13.7 11.638 13.643C11.605 13.586 11.587 13.522 11.587 13.456L11.587 12.996L11.316 12.778C11.28 12.749 11.251 12.714 11.229 12.674C11.207 12.634 11.193 12.589 11.188 12.544C11.183 12.498 11.187 12.452 11.2 12.408C11.213 12.364 11.235 12.324 11.264 12.288C11.303 12.24 11.354 12.204 11.411 12.182C11.469 12.16 11.531 12.154 11.592 12.163C11.653 12.173 11.71 12.198 11.758 12.237L11.973 12.409L12.193 12.235C12.241 12.197 12.298 12.172 12.358 12.163C12.418 12.154 12.48 12.16 12.537 12.182C12.594 12.203 12.644 12.239 12.683 12.286ZM7.643 10.367C8.121 10.367 8.51 10.757 8.51 11.238C8.51 11.391 8.47 11.541 8.394 11.673C8.318 11.805 8.208 11.915 8.076 11.992C7.944 12.068 7.795 12.109 7.642 12.109C7.49 12.108 7.34 12.068 7.208 11.991C7.076 11.915 6.967 11.805 6.891 11.673C6.815 11.541 6.775 11.391 6.775 11.239C6.775 11.086 6.814 10.936 6.89 10.804C6.966 10.672 7.076 10.562 7.208 10.485C7.34 10.408 7.489 10.368 7.642 10.367ZM16.349 10.367C16.829 10.367 17.217 10.757 17.217 11.238C17.217 11.391 17.177 11.541 17.101 11.673C17.025 11.805 16.915 11.915 16.783 11.992C16.651 12.068 16.502 12.109 16.349 12.109C16.197 12.108 16.047 12.068 15.915 11.991C15.783 11.915 15.674 11.805 15.598 11.673C15.522 11.541 15.482 11.391 15.482 11.239C15.482 11.086 15.521 10.936 15.597 10.804C15.673 10.672 15.783 10.562 15.915 10.485C16.047 10.408 16.196 10.368 16.349 10.367ZM7.44 2.3L7.437 2.302C7.379 2.327 7.326 2.36 7.277 2.401C7.229 2.441 7.187 2.488 7.152 2.54L7.147 2.546C7.009 2.735 6.889 3.013 6.799 3.378C6.629 4.07 6.583 5.009 6.675 6.16C7.105 6.032 7.574 5.952 8.079 5.923L8.089 5.922L8.108 5.888C8.154 5.806 8.203 5.727 8.256 5.649C8.379 4.878 8.278 3.957 8.003 3.205C7.869 2.841 7.706 2.555 7.55 2.392C7.518 2.358 7.482 2.328 7.443 2.302L7.44 2.3ZM16.614 2.34L16.612 2.341C16.573 2.367 16.537 2.397 16.505 2.431C16.349 2.594 16.185 2.881 16.052 3.245C15.762 4.039 15.665 5.021 15.822 5.817L15.88 5.914L15.888 5.928L15.918 5.928C16.414 5.928 16.908 6 17.384 6.14C17.47 5.016 17.422 4.097 17.256 3.418C17.166 3.053 17.046 2.775 16.907 2.586L16.903 2.58C16.868 2.528 16.826 2.48 16.778 2.44C16.729 2.4 16.676 2.366 16.618 2.341L16.614 2.341Z"],
	"grok": ["M9.27 15.29L17.248 9.393C17.639 9.103 18.198 9.216 18.385 9.665C19.365 12.034 18.927 14.88 16.975 16.834C15.024 18.788 12.308 19.216 9.826 18.24L7.115 19.497C11.004 22.158 15.726 21.5 18.677 18.544C21.018 16.2 21.743 13.005 21.065 10.124L21.071 10.131C20.088 5.899 21.313 4.207 23.821 0.748C23.881 0.666 23.941 0.584 24 0.5L20.699 3.805L20.699 3.795L9.267 15.292M7.623 16.723C4.831 14.053 5.313 9.922 7.694 7.539C9.455 5.776 12.341 5.056 14.86 6.114L17.565 4.864C17.003 4.45 16.388 4.114 15.736 3.864C14.648 3.419 13.484 3.192 12.308 3.195C11.133 3.199 9.97 3.433 8.885 3.885C7.8 4.337 6.814 4.998 5.984 5.83C3.451 8.366 2.654 12.266 4.022 15.594C5.044 18.081 3.369 19.84 1.682 21.616C1.083 22.246 0.483 22.875 0 23.541L7.62 16.726"],
	"groq": ["M12.036 2C8.183 1.965 5.036 5 5 8.781C4.965 12.563 8.055 15.653 11.908 15.688L14.328 15.688L14.328 13.122L12.036 13.122C9.629 13.15 7.656 11.256 7.628 8.892C7.599 6.53 9.529 4.594 11.936 4.566L12.036 4.566C14.443 4.566 16.394 6.481 16.401 8.844L16.401 15.149C16.401 17.491 14.457 19.399 12.078 19.428C11.516 19.424 10.959 19.312 10.44 19.097C9.92 18.883 9.446 18.57 9.045 18.176L7.194 19.994C7.834 20.623 8.589 21.122 9.417 21.466C10.245 21.81 11.132 21.991 12.029 22L12.121 22C15.924 21.944 18.979 18.917 19 15.184L19 8.684C18.907 4.963 15.817 2 12.036 2Z"],
	"openrouter": ["M18.654 3.87C19.547 3.87 20.424 4.105 21.197 4.552C21.971 4.998 22.613 5.64 23.059 6.414C23.506 7.187 23.741 8.064 23.741 8.957C23.741 9.85 23.506 10.727 23.059 11.5C22.613 12.274 21.971 12.916 21.198 13.362C20.424 13.809 19.547 14.044 18.654 14.044L23.7 19.09C24.34 19.731 23.887 20.827 22.98 20.827L8.48 20.827C6.992 20.827 5.529 20.435 4.241 19.691C2.952 18.947 1.881 17.876 1.137 16.588C0.393 15.299 0.001 13.836 0.001 12.348C0.001 10.86 0.393 9.397 1.137 8.109C1.881 6.82 2.952 5.749 4.24 5.005C5.529 4.261 6.992 3.869 8.48 3.869L18.655 3.869ZM8.479 7.26C7.586 7.26 6.708 7.495 5.935 7.942C5.162 8.388 4.519 9.031 4.073 9.804C3.626 10.577 3.391 11.455 3.391 12.348C3.391 13.241 3.626 14.119 4.073 14.892C4.519 15.665 5.162 16.308 5.935 16.754C6.708 17.201 7.586 17.436 8.479 17.436C9.372 17.436 10.249 17.201 11.023 16.754C11.796 16.308 12.438 15.666 12.885 14.892C13.331 14.119 13.566 13.241 13.566 12.349C13.566 11.456 13.331 10.578 12.885 9.805C12.438 9.031 11.796 8.389 11.023 7.943C10.249 7.496 9.372 7.261 8.479 7.261Z"],
	"deepseek": ["M23.748 4.482C23.494 4.358 23.384 4.595 23.236 4.716C23.185 4.755 23.142 4.806 23.099 4.852C22.727 5.249 22.293 5.509 21.726 5.478C20.897 5.432 20.189 5.692 19.563 6.326C19.43 5.544 18.988 5.078 18.316 4.778C17.964 4.622 17.608 4.467 17.361 4.128C17.189 3.887 17.142 3.618 17.056 3.354C17.001 3.194 16.946 3.031 16.763 3.004C16.563 2.973 16.485 3.14 16.407 3.28C16.094 3.852 15.973 4.482 15.985 5.12C16.012 6.556 16.618 7.7 17.823 8.513C17.96 8.606 17.995 8.7 17.952 8.836C17.87 9.116 17.772 9.388 17.686 9.669C17.631 9.848 17.549 9.886 17.357 9.809C16.708 9.53 16.119 9.13 15.621 8.629C14.764 7.801 13.99 6.887 13.024 6.171C12.8 6.006 12.57 5.849 12.335 5.7C11.35 4.743 12.465 3.957 12.723 3.864C12.993 3.766 12.816 3.432 11.944 3.436C11.072 3.44 10.274 3.731 9.257 4.12C9.106 4.178 8.95 4.224 8.792 4.257C7.842 4.078 6.87 4.044 5.909 4.155C4.024 4.365 2.519 5.257 1.412 6.778C0.082 8.606 -0.231 10.684 0.152 12.85C0.555 15.134 1.721 17.025 3.512 18.503C5.37 20.036 7.509 20.787 9.95 20.643C11.432 20.558 13.083 20.359 14.944 18.783C15.414 19.017 15.906 19.11 16.724 19.18C17.354 19.239 17.96 19.15 18.429 19.052C19.164 18.896 19.113 18.215 18.848 18.091C16.693 17.087 17.166 17.496 16.735 17.165C17.831 15.869 19.481 14.523 20.127 10.162C20.177 9.815 20.134 9.597 20.127 9.317C20.123 9.147 20.162 9.08 20.357 9.061C20.898 9.005 21.423 8.844 21.902 8.586C23.298 7.823 23.862 6.571 23.995 5.069C24.015 4.839 23.991 4.602 23.748 4.481ZM11.581 18C9.492 16.358 8.479 15.817 8.061 15.84C7.669 15.864 7.74 16.311 7.826 16.603C7.916 16.891 8.033 17.089 8.197 17.342C8.311 17.509 8.389 17.758 8.084 17.945C7.411 18.361 6.242 17.805 6.187 17.778C4.826 16.976 3.687 15.918 2.886 14.471C2.112 13.078 1.662 11.584 1.588 9.989C1.568 9.603 1.681 9.467 2.065 9.397C2.569 9.301 3.086 9.287 3.594 9.358C5.726 9.67 7.54 10.623 9.062 12.132C9.93 12.992 10.587 14.019 11.264 15.023C11.984 16.089 12.758 17.105 13.744 17.937C14.092 18.229 14.369 18.451 14.635 18.614C13.833 18.704 12.495 18.724 11.581 18ZM12.581 11.56C12.581 11.51 12.593 11.461 12.616 11.417C12.639 11.373 12.672 11.336 12.713 11.307C12.754 11.279 12.801 11.261 12.85 11.255C12.9 11.249 12.95 11.255 12.996 11.273C13.035 11.287 13.071 11.309 13.101 11.338C13.132 11.366 13.156 11.401 13.172 11.44C13.188 11.478 13.197 11.519 13.196 11.561C13.196 11.602 13.188 11.642 13.173 11.679C13.157 11.717 13.134 11.751 13.105 11.779C13.076 11.808 13.042 11.831 13.005 11.846C12.967 11.861 12.927 11.869 12.886 11.868C12.846 11.868 12.806 11.86 12.769 11.845C12.731 11.829 12.698 11.807 12.669 11.778C12.641 11.749 12.619 11.715 12.604 11.678C12.589 11.64 12.581 11.6 12.582 11.56ZM15.691 13.156C15.491 13.237 15.292 13.307 15.101 13.316C14.958 13.321 14.816 13.301 14.68 13.258C14.544 13.215 14.416 13.148 14.303 13.062C14.029 12.832 13.833 12.704 13.751 12.304C13.723 12.109 13.728 11.91 13.767 11.716C13.837 11.389 13.759 11.179 13.528 10.989C13.341 10.833 13.102 10.79 12.84 10.79C12.75 10.785 12.663 10.758 12.586 10.712C12.476 10.658 12.386 10.522 12.472 10.354C12.5 10.3 12.632 10.168 12.664 10.144C13.02 9.942 13.431 10.008 13.81 10.16C14.162 10.304 14.428 10.568 14.811 10.942C15.202 11.393 15.273 11.518 15.496 11.856C15.672 12.121 15.832 12.393 15.941 12.704C16.008 12.899 15.922 13.058 15.691 13.156Z"],
	"qwen": ["M12.604 1.34C12.997 2.03 13.388 2.722 13.778 3.415C13.788 3.433 13.802 3.45 13.818 3.464C13.834 3.477 13.853 3.488 13.873 3.495C13.893 3.502 13.914 3.506 13.935 3.506L19.487 3.506C19.661 3.506 19.809 3.616 19.933 3.833L21.387 6.403C21.577 6.74 21.627 6.881 21.411 7.24C21.151 7.67 20.898 8.104 20.651 8.54L20.284 9.198C20.178 9.394 20.061 9.478 20.244 9.71L22.896 14.347C23.068 14.648 23.007 14.841 22.853 15.117C22.416 15.902 21.971 16.681 21.518 17.457C21.359 17.729 21.166 17.832 20.838 17.827C20.061 17.811 19.286 17.817 18.511 17.843C18.494 17.844 18.478 17.849 18.464 17.858C18.45 17.866 18.438 17.879 18.43 17.893C17.536 19.477 16.634 21.057 15.725 22.633C15.556 22.926 15.345 22.996 15 22.997C14.003 23 12.998 23.001 11.983 22.999C11.92 22.999 11.858 22.988 11.799 22.966C11.74 22.944 11.685 22.912 11.637 22.872C11.59 22.831 11.549 22.783 11.518 22.728L10.183 20.405C10.178 20.395 10.171 20.386 10.162 20.378C10.154 20.371 10.144 20.365 10.133 20.361C10.123 20.357 10.111 20.356 10.1 20.356L4.982 20.356C4.697 20.386 4.429 20.355 4.177 20.264L2.574 17.494C2.527 17.412 2.501 17.319 2.501 17.224C2.501 17.13 2.525 17.036 2.572 16.954L3.779 14.834C3.796 14.804 3.805 14.77 3.805 14.736C3.805 14.701 3.796 14.667 3.779 14.637C3.15 13.548 2.525 12.458 1.904 11.365L1.114 9.97C0.954 9.66 0.941 9.474 1.209 9.005C1.674 8.192 2.136 7.38 2.596 6.569C2.728 6.335 2.9 6.235 3.18 6.234C4.043 6.23 4.906 6.23 5.769 6.233C5.783 6.233 5.798 6.23 5.811 6.225C5.825 6.22 5.838 6.213 5.849 6.203C5.86 6.194 5.869 6.183 5.876 6.17L8.682 1.275C8.71 1.226 8.747 1.181 8.79 1.145C8.834 1.108 8.884 1.079 8.937 1.059C8.991 1.039 9.047 1.029 9.104 1.029C9.628 1.028 10.157 1.029 10.687 1.023L11.704 1C12.045 0.997 12.428 1.032 12.604 1.34ZM9.172 1.743C9.165 1.743 9.158 1.744 9.151 1.747C9.145 1.749 9.139 1.753 9.133 1.757C9.128 1.762 9.124 1.767 9.12 1.773L6.254 6.788C6.24 6.812 6.221 6.831 6.197 6.845C6.173 6.859 6.146 6.866 6.119 6.866L3.253 6.866C3.197 6.866 3.183 6.891 3.212 6.94L9.022 17.096C9.047 17.138 9.035 17.158 8.988 17.159L6.193 17.174C6.166 17.173 6.139 17.177 6.113 17.186C6.088 17.195 6.064 17.209 6.043 17.227C6.023 17.245 6.006 17.266 5.993 17.29L4.673 19.6C4.629 19.678 4.652 19.718 4.741 19.718L10.457 19.726C10.503 19.726 10.537 19.746 10.561 19.787L11.964 22.241C12.01 22.322 12.056 22.323 12.103 22.241L17.109 13.481L17.892 12.099C17.896 12.092 17.901 12.086 17.907 12.082C17.914 12.077 17.921 12.074 17.928 12.072C17.936 12.07 17.944 12.07 17.952 12.072C17.959 12.074 17.966 12.077 17.973 12.082C17.979 12.086 17.984 12.092 17.988 12.099L19.412 14.629C19.419 14.642 19.428 14.653 19.439 14.662C19.45 14.671 19.463 14.679 19.477 14.684C19.49 14.689 19.505 14.691 19.519 14.691L22.282 14.671C22.287 14.671 22.291 14.67 22.296 14.669C22.3 14.667 22.304 14.665 22.308 14.662C22.312 14.659 22.315 14.655 22.317 14.651C22.32 14.645 22.322 14.638 22.322 14.631C22.322 14.624 22.32 14.617 22.317 14.611L19.417 9.525C19.41 9.514 19.405 9.501 19.403 9.488C19.4 9.475 19.4 9.462 19.403 9.449C19.405 9.436 19.41 9.423 19.417 9.412L19.71 8.905L20.83 6.928C20.854 6.887 20.842 6.866 20.795 6.866L9.2 6.866C9.141 6.866 9.127 6.84 9.157 6.789L10.591 4.284C10.598 4.273 10.603 4.26 10.606 4.247C10.608 4.234 10.608 4.22 10.606 4.207C10.603 4.194 10.598 4.181 10.591 4.17L9.225 1.774C9.222 1.768 9.217 1.762 9.212 1.757C9.206 1.753 9.2 1.749 9.193 1.747C9.186 1.744 9.179 1.743 9.172 1.743ZM15.462 9.763C15.508 9.763 15.52 9.783 15.496 9.823L14.664 11.288L12.051 15.873C12.048 15.879 12.043 15.884 12.038 15.889C12.033 15.893 12.027 15.896 12.021 15.899C12.014 15.901 12.008 15.902 12.001 15.902C11.991 15.902 11.981 15.899 11.972 15.894C11.963 15.889 11.956 15.882 11.951 15.873L8.498 9.841C8.478 9.807 8.488 9.789 8.526 9.787L8.742 9.775L15.464 9.763Z"],
	"kimi": ["M21.846 0C22.184 0 22.515 0.089 22.807 0.258C23.1 0.426 23.343 0.669 23.511 0.961C23.68 1.254 23.769 1.585 23.769 1.923C23.769 2.261 23.68 2.592 23.511 2.884C23.343 3.177 23.1 3.42 22.808 3.588C22.515 3.757 22.184 3.846 21.846 3.846L20.15 3.846C20.12 3.846 20.091 3.84 20.063 3.829C20.036 3.818 20.011 3.801 19.99 3.78C19.968 3.759 19.952 3.734 19.94 3.707C19.929 3.679 19.923 3.65 19.923 3.62L19.923 1.923C19.923 0.861 20.784 0 21.846 0Z", "M11.065 11.199L18.322 3.999C18.459 3.863 18.382 3.589 18.206 3.589L14.3 3.589C14.278 3.589 14.256 3.594 14.236 3.603C14.216 3.611 14.198 3.624 14.183 3.64L6.363 11.396C6.241 11.516 6.061 11.409 6.061 11.217L6.061 3.82C6.061 3.693 5.978 3.59 5.876 3.59L3.186 3.59C3.083 3.59 3 3.693 3 3.82L3 19.77C3 19.898 3.083 20 3.186 20L5.876 20C5.979 20 6.062 19.898 6.062 19.77L6.062 16.52C6.062 16.451 6.087 16.385 6.131 16.342L8.555 13.936C8.572 13.918 8.593 13.904 8.617 13.895C8.64 13.886 8.666 13.884 8.691 13.887C8.715 13.89 8.739 13.899 8.76 13.913L15.244 18.685C16.274 19.387 17.459 19.827 18.697 19.968C18.805 19.98 18.897 19.873 18.897 19.738L18.897 16.678C18.897 16.561 18.827 16.466 18.733 16.451C18.006 16.334 17.314 16.058 16.706 15.644L11.093 11.58C10.976 11.502 10.961 11.301 11.065 11.199Z"],
	"lmstudio": ["M2.84 2C2.616 2 2.397 2.059 2.203 2.171C2.01 2.282 1.849 2.443 1.737 2.637C1.625 2.83 1.566 3.05 1.566 3.273C1.566 3.497 1.625 3.717 1.737 3.91C1.849 4.104 2.01 4.265 2.203 4.376C2.397 4.488 2.616 4.547 2.84 4.547L16.947 4.547C17.171 4.547 17.39 4.488 17.584 4.376C17.777 4.265 17.938 4.104 18.05 3.91C18.162 3.717 18.22 3.497 18.22 3.274C18.22 3.05 18.162 2.83 18.05 2.637C17.938 2.443 17.777 2.282 17.584 2.171C17.39 2.059 17.171 2 16.947 2L2.84 2ZM7.935 5.33C7.711 5.33 7.492 5.389 7.298 5.501C7.104 5.612 6.943 5.773 6.832 5.967C6.72 6.161 6.661 6.38 6.661 6.604C6.661 6.828 6.72 7.047 6.832 7.241C6.943 7.435 7.104 7.596 7.298 7.707C7.492 7.819 7.711 7.878 7.935 7.878L22.04 7.878C22.259 7.872 22.474 7.809 22.662 7.696C22.85 7.582 23.006 7.422 23.114 7.231C23.222 7.04 23.278 6.824 23.278 6.604C23.278 6.385 23.222 6.169 23.114 5.978C23.006 5.787 22.85 5.627 22.662 5.513C22.474 5.4 22.259 5.337 22.04 5.331L7.935 5.331ZM3.624 9.935C3.624 9.231 4.194 8.661 4.898 8.661L19.004 8.661C19.223 8.667 19.438 8.73 19.626 8.843C19.814 8.957 19.97 9.117 20.078 9.308C20.186 9.499 20.242 9.715 20.242 9.935C20.242 10.154 20.186 10.37 20.078 10.561C19.97 10.752 19.814 10.912 19.626 11.026C19.438 11.139 19.223 11.202 19.004 11.208L4.898 11.208C4.195 11.208 3.624 10.638 3.624 9.935ZM1.273 12.188C1.049 12.188 0.83 12.247 0.636 12.359C0.443 12.47 0.282 12.631 0.17 12.825C0.058 13.018 -0.001 13.238 -0.001 13.462C-0.001 13.685 0.058 13.905 0.17 14.098C0.282 14.292 0.443 14.453 0.636 14.564C0.83 14.676 1.049 14.735 1.273 14.735L15.38 14.735C15.599 14.729 15.814 14.666 16.002 14.553C16.19 14.439 16.346 14.279 16.454 14.088C16.562 13.897 16.618 13.681 16.618 13.462C16.618 13.242 16.562 13.026 16.454 12.835C16.346 12.644 16.19 12.484 16.002 12.37C15.814 12.257 15.599 12.194 15.38 12.188L1.273 12.188ZM3.624 16.792C3.624 16.088 4.194 15.518 4.898 15.518L19.004 15.518C19.228 15.518 19.447 15.577 19.641 15.689C19.834 15.8 19.995 15.961 20.107 16.155C20.219 16.348 20.277 16.568 20.277 16.791C20.277 17.015 20.219 17.235 20.107 17.428C19.995 17.622 19.834 17.783 19.641 17.894C19.447 18.006 19.228 18.065 19.004 18.065L4.898 18.065C4.195 18.065 3.624 17.495 3.624 16.792ZM13.029 18.849C12.805 18.849 12.586 18.908 12.392 19.02C12.199 19.131 12.038 19.292 11.926 19.486C11.814 19.679 11.755 19.899 11.755 20.123C11.755 20.346 11.814 20.566 11.926 20.759C12.038 20.953 12.199 21.114 12.392 21.225C12.586 21.337 12.805 21.396 13.029 21.396L22.727 21.396C22.951 21.396 23.17 21.337 23.364 21.225C23.557 21.114 23.718 20.953 23.83 20.759C23.942 20.566 24.001 20.346 24.001 20.123C24.001 19.899 23.942 19.679 23.83 19.486C23.718 19.292 23.557 19.131 23.364 19.02C23.17 18.908 22.951 18.849 22.727 18.849L13.029 18.849Z", "M2.84 2C2.616 2 2.397 2.059 2.203 2.171C2.01 2.282 1.849 2.443 1.737 2.637C1.625 2.83 1.566 3.05 1.566 3.273C1.566 3.497 1.625 3.717 1.737 3.91C1.849 4.104 2.01 4.265 2.203 4.376C2.397 4.488 2.616 4.547 2.84 4.547L13.127 4.547C13.346 4.541 13.561 4.478 13.749 4.365C13.937 4.251 14.093 4.091 14.201 3.9C14.309 3.709 14.365 3.493 14.365 3.274C14.365 3.054 14.309 2.838 14.201 2.647C14.093 2.456 13.937 2.296 13.749 2.182C13.561 2.069 13.346 2.006 13.127 2L2.84 2ZM7.935 5.33C7.711 5.33 7.492 5.389 7.298 5.501C7.104 5.612 6.943 5.773 6.832 5.967C6.72 6.161 6.661 6.38 6.661 6.604C6.661 6.828 6.72 7.047 6.832 7.241C6.943 7.435 7.104 7.596 7.298 7.707C7.492 7.819 7.711 7.878 7.935 7.878L18.22 7.878C18.439 7.872 18.654 7.809 18.842 7.696C19.03 7.582 19.186 7.422 19.294 7.231C19.402 7.04 19.458 6.824 19.458 6.604C19.458 6.385 19.402 6.169 19.294 5.978C19.186 5.787 19.03 5.627 18.842 5.513C18.654 5.4 18.439 5.337 18.22 5.331L7.935 5.331ZM3.624 9.935C3.624 9.231 4.194 8.661 4.898 8.661L15.184 8.661C15.408 8.661 15.627 8.72 15.821 8.832C16.014 8.943 16.175 9.104 16.287 9.298C16.399 9.491 16.457 9.711 16.457 9.935C16.457 10.158 16.399 10.378 16.287 10.571C16.175 10.765 16.014 10.926 15.821 11.037C15.627 11.149 15.408 11.208 15.184 11.208L4.898 11.208C4.195 11.208 3.624 10.638 3.624 9.935ZM1.273 12.188C1.049 12.188 0.83 12.247 0.636 12.359C0.443 12.47 0.282 12.631 0.17 12.825C0.058 13.018 -0.001 13.238 -0.001 13.462C-0.001 13.685 0.058 13.905 0.17 14.098C0.282 14.292 0.443 14.453 0.636 14.564C0.83 14.676 1.049 14.735 1.273 14.735L11.56 14.735C11.779 14.729 11.994 14.666 12.182 14.553C12.37 14.439 12.526 14.279 12.634 14.088C12.742 13.897 12.798 13.681 12.798 13.462C12.798 13.242 12.742 13.026 12.634 12.835C12.526 12.644 12.37 12.484 12.182 12.37C11.994 12.257 11.779 12.194 11.56 12.188L1.273 12.188ZM3.624 16.792C3.624 16.088 4.194 15.518 4.898 15.518L15.184 15.518C15.408 15.518 15.627 15.577 15.821 15.689C16.014 15.8 16.175 15.961 16.287 16.155C16.399 16.348 16.457 16.568 16.457 16.791C16.457 17.015 16.399 17.235 16.287 17.428C16.175 17.622 16.014 17.783 15.821 17.894C15.627 18.006 15.408 18.065 15.184 18.065L4.898 18.065C4.195 18.065 3.624 17.495 3.624 16.792ZM13.029 18.849C12.805 18.849 12.586 18.908 12.392 19.02C12.199 19.131 12.038 19.292 11.926 19.486C11.814 19.679 11.755 19.899 11.755 20.123C11.755 20.346 11.814 20.566 11.926 20.759C12.038 20.953 12.199 21.114 12.392 21.225C12.586 21.337 12.805 21.396 13.029 21.396L18.809 21.396C19.033 21.396 19.252 21.337 19.446 21.225C19.639 21.114 19.8 20.953 19.912 20.759C20.024 20.566 20.083 20.346 20.083 20.123C20.083 19.899 20.024 19.679 19.912 19.486C19.8 19.292 19.639 19.131 19.446 19.02C19.252 18.908 19.033 18.849 18.809 18.849L13.029 18.849Z"],
	"meta": ["M6.897 4C8.812 4 10.413 4.932 12.327 7.376L12.609 7.003C12.799 6.757 12.992 6.519 13.189 6.293L13.502 5.943C14.588 4.788 15.792 4 17.225 4C18.498 4 19.694 4.557 20.716 5.516L20.934 5.729C22.664 7.494 23.851 10.439 23.987 13.755L23.998 14.147L24 14.397C24 15.898 23.72 17.156 23.182 18.097L23.042 18.327L22.934 18.48C22.633 18.9 22.27 19.238 21.848 19.489L21.583 19.631L21.496 19.671C21.397 19.715 21.296 19.754 21.194 19.789C20.765 19.931 20.316 20.001 19.864 19.997C19.34 19.997 18.868 19.93 18.426 19.782C17.812 19.578 17.263 19.222 16.7 18.666L16.473 18.431C15.72 17.619 14.939 16.455 13.98 14.845L12.55 12.435L12.006 11.54L10.24 14.67L9.897 15.262C7.597 19.156 6.227 20 4.356 20C3.146 20 2.151 19.58 1.42 18.818L1.252 18.634C0.768 18.061 0.415 17.323 0.209 16.445L0.142 16.125C0.065 15.7 0.019 15.269 0.006 14.837L0 14.468C0.002 13.723 0.06 12.978 0.174 12.238L0.274 11.665C0.572 10.135 1.102 8.707 1.81 7.508L2.019 7.168C3.196 5.338 4.808 4.115 6.634 4.008L6.897 4ZM6.864 6.615L6.663 6.625C5.833 6.708 5.057 7.298 4.411 8.202L4.273 8.401L4.263 8.419C3.593 9.436 3.078 10.797 2.807 12.264L2.803 12.286C2.666 13.03 2.597 13.784 2.596 14.54L2.598 14.728C2.602 14.908 2.615 15.088 2.638 15.268L2.681 15.559C2.773 16.062 2.938 16.467 3.167 16.767L3.284 16.904C3.587 17.227 3.982 17.396 4.454 17.396C5.554 17.396 6.25 16.72 8.15 13.755L10.325 10.355L10.779 9.654L10.64 9.456C9.11 7.3 8.084 6.616 6.864 6.616ZM17.06 6.063L16.884 6.07C16.249 6.118 15.661 6.429 15.064 7.003L14.868 7.201C14.429 7.663 13.981 8.265 13.501 9.008L13.767 9.406C13.947 9.68 14.129 9.966 14.317 10.264L14.61 10.739L16.006 13.074L16.701 14.188C17.284 15.114 17.731 15.788 18.109 16.27L18.322 16.532C18.604 16.858 18.851 17.072 19.099 17.205L19.201 17.255C19.428 17.355 19.658 17.393 19.919 17.393C20.095 17.395 20.269 17.37 20.437 17.32C20.775 17.216 21.047 17 21.25 16.683L21.345 16.52L21.422 16.358C21.616 15.899 21.712 15.298 21.712 14.573L21.706 14.124C21.626 11.253 20.768 8.752 19.506 7.326L19.33 7.137C18.66 6.454 17.886 6.063 17.06 6.063Z"],
	"gemma": ["M12.34 5.953C12.232 5.584 12.149 5.208 12.093 4.828L12.093 3.72C13.118 3.73 14.132 3.931 15.084 4.313C16.035 4.695 16.907 5.251 17.655 5.952L12.34 5.952ZM11.65 5.953C11.763 5.58 11.849 5.198 11.907 4.808L11.907 3.72C10.882 3.73 9.868 3.931 8.916 4.313C7.965 4.695 7.093 5.251 6.345 5.952L11.649 5.952ZM6.217 6.14L11.59 6.14C11.512 6.376 11.423 6.608 11.323 6.836C10.91 7.823 10.313 8.723 9.563 9.486L6.216 6.14ZM5.953 5.953L2.977 5.953L2.977 6.14L5.892 6.14C5.152 6.909 4.565 7.811 4.162 8.798C3.758 9.785 3.545 10.84 3.535 11.907L0 11.907L0 12.093L3.535 12.093C3.545 13.16 3.758 14.215 4.162 15.202C4.565 16.189 5.152 17.091 5.892 17.86L2.977 17.86L2.977 18.046L5.953 18.046L5.953 21.023L6.14 21.023L6.14 18.108C6.909 18.848 7.811 19.435 8.798 19.838C9.785 20.242 10.84 20.455 11.907 20.465L11.907 24L12.093 24L12.093 20.465C13.16 20.455 14.215 20.242 15.202 19.838C16.189 19.435 17.091 18.848 17.86 18.108L17.86 21.023L18.046 21.023L18.046 18.046L21.023 18.046L21.023 17.86L18.108 17.86C18.848 17.091 19.435 16.189 19.838 15.202C20.242 14.215 20.455 13.16 20.465 12.093L24 12.093L24 11.907L20.465 11.907C20.455 10.84 20.242 9.785 19.838 8.798C19.435 7.811 18.848 6.909 18.108 6.14L21.023 6.14L21.023 5.953L18.046 5.953L18.046 2.977L17.86 2.977L17.86 5.892C17.091 5.152 16.189 4.565 15.202 4.162C14.215 3.758 13.16 3.545 12.093 3.535L12.093 0L11.907 0L11.907 3.535C10.84 3.545 9.785 3.758 8.798 4.162C7.811 4.565 6.909 5.152 6.14 5.892L6.14 2.977L5.953 2.977L5.953 5.953ZM12.093 20.279C13.118 20.269 14.133 20.067 15.084 19.685C16.035 19.303 16.907 18.747 17.655 18.046L12.34 18.046C12.232 18.413 12.15 18.789 12.093 19.172L12.093 20.279ZM11.907 19.192C11.849 18.804 11.763 18.421 11.649 18.046L6.345 18.046C7.093 18.747 7.965 19.303 8.916 19.685C9.867 20.067 10.882 20.269 11.907 20.279L11.907 19.192ZM3.721 11.907L4.828 11.907C5.208 11.851 5.584 11.769 5.953 11.66L5.953 6.345C5.252 7.093 4.696 7.965 4.314 8.916C3.932 9.868 3.731 10.882 3.721 11.907ZM4.808 12.093L3.72 12.093C3.73 13.118 3.931 14.132 4.313 15.084C4.695 16.035 5.251 16.907 5.952 17.655L5.952 12.351C5.577 12.237 5.194 12.151 4.807 12.093ZM20.278 11.907C20.268 10.882 20.067 9.868 19.685 8.916C19.303 7.965 18.747 7.093 18.046 6.345L18.046 11.66C18.413 11.768 18.789 11.85 19.172 11.907L20.279 11.907ZM19.192 12.093C18.802 12.151 18.42 12.237 18.046 12.351L18.046 17.655C18.747 16.907 19.303 16.035 19.685 15.084C20.067 14.133 20.269 13.118 20.279 12.093L19.192 12.093ZM17.86 17.783L17.86 12.41C17.624 12.488 17.392 12.577 17.164 12.677C16.177 13.09 15.277 13.687 14.514 14.437L17.86 17.783ZM17.86 11.603L17.86 6.153L17.848 6.14L12.397 6.14C12.473 6.375 12.559 6.608 12.657 6.836C13.089 7.838 13.706 8.75 14.476 9.524C15.25 10.294 16.162 10.911 17.164 11.344C17.392 11.441 17.624 11.527 17.86 11.603ZM6.14 17.848L6.14 12.41C6.375 12.488 6.608 12.577 6.836 12.677C7.84 13.097 8.753 13.708 9.524 14.476C10.292 15.247 10.903 16.16 11.323 17.164C11.423 17.392 11.513 17.624 11.59 17.86L6.152 17.86L6.14 17.848ZM6.14 11.603L6.14 6.326L9.43 9.616C8.676 10.343 7.797 10.929 6.836 11.344C6.608 11.441 6.376 11.527 6.14 11.603ZM12.397 17.86L17.674 17.86L14.384 14.57C13.657 15.324 13.071 16.203 12.656 17.164C12.559 17.392 12.473 17.624 12.397 17.86ZM10.05 10.05C9.22 10.876 8.243 11.541 7.17 12.01C8.245 12.467 9.223 13.125 10.05 13.95C10.875 14.777 11.533 15.755 11.99 16.83C12.459 15.757 13.124 14.78 13.95 13.95C14.777 13.125 15.755 12.467 16.83 12.01C15.757 11.541 14.78 10.876 13.95 10.05C13.124 9.22 12.459 8.243 11.99 7.17C11.533 8.245 10.875 9.223 10.05 10.05Z"],
	"opencode": ["M16 6L8 6L8 18L16 18L16 6ZM20 22L4 22L4 2L20 2L20 22Z"],
	"cursor": ["M22.106 5.68L12.5 0.135C12.191 -0.043 11.811 -0.043 11.502 0.135L1.893 5.68C1.634 5.83 1.474 6.107 1.474 6.406L1.474 17.592C1.474 17.892 1.634 18.169 1.894 18.319L11.501 23.866C11.81 24.044 12.19 24.044 12.499 23.866L22.107 18.319C22.367 18.169 22.527 17.892 22.527 17.592L22.527 6.407C22.526 6.107 22.366 5.831 22.107 5.681ZM21.503 6.856L12.228 22.92C12.165 23.028 12 22.984 12 22.859L12 12.34C12 12.13 11.887 11.935 11.705 11.83L2.595 6.57C2.488 6.508 2.532 6.342 2.657 6.342L21.207 6.342C21.471 6.342 21.635 6.628 21.503 6.856Z"]
};
// src/brands.ts
var table = [
	["claude", "claude"],
	["anthropic", "claude"],
	["codex", "openai"],
	["openai", "openai"],
	["gpt", "openai"],
	["gemma", "gemma"],
	["gemini", "gemini"],
	["mistral", "mistral"],
	["mixtral", "mistral"],
	["ollama", "ollama"],
	["grok", "grok"],
	["groq", "groq"],
	["openrouter", "openrouter"],
	["deepseek", "deepseek"],
	["qwen", "qwen"],
	["kimi", "kimi"],
	["moonshot", "kimi"],
	["lm studio", "lmstudio"],
	["lmstudio", "lmstudio"],
	["llama", "meta"],
	["opencode", "opencode"],
	["cursor", "cursor"]
];
/** The brand a model or agent name points at ("claude-haiku-5-5", "Qwen 3 (4B)", "Codex"), if there is a mark for it. */
function brandFor(name) {
	const lower = name.toLowerCase();
	return table.find(([word]) => lower.includes(word))?.[1];
}
/** A mark's fill: its brand color, a gradient's two stops, or null for the one-color marks that follow the text. */
function brandFill(brand) {
	switch (brand) {
		case "claude": return "#D97757";
		case "gemini":
		case "gemma": return ["#4F8BF7", "#9B72F2"];
		case "mistral": return "#FA520F";
		case "groq": return "#F55036";
		case "openrouter": return "#8B8EFF";
		case "deepseek": return "#5B7BFF";
		case "qwen": return "#7C78F5";
		case "kimi": return "#3A9BFF";
		case "meta": return "#1D9BF0";
		default: return null;
	}
}
// src/AgentMark.svelte
var next = 0;
var root$3 = /* @__PURE__ */ from_svg(`<svg class="mark laptop svelte-1vbdbgh" viewBox="0 0 24 24" aria-hidden="true"><path d="M18 5a2 2 0 0 1 2 2v8.526a2 2 0 0 0 .212.897l1.068 2.127a1 1 0 0 1-.9 1.45H3.62a1 1 0 0 1-.9-1.45l1.068-2.127A2 2 0 0 0 4 15.526V7a2 2 0 0 1 2-2z"></path><path d="M20.054 15.987H3.946"></path></svg>`);
var root_1$2 = /* @__PURE__ */ from_svg(`<defs><linearGradient x1="0" y1="1" x2="1" y2="0"><stop offset="0"></stop><stop offset="1"></stop></linearGradient></defs>`);
var root_2$2 = /* @__PURE__ */ from_svg(`<path fill-rule="evenodd"></path>`);
var root_3$2 = /* @__PURE__ */ from_svg(`<svg class="mark svelte-1vbdbgh" viewBox="0 0 24 24" aria-hidden="true"><!><!></svg>`);
var root_4$2 = /* @__PURE__ */ from_svg(`<svg class="mark tile svelte-1vbdbgh" viewBox="0 0 24 24" aria-hidden="true"><defs><linearGradient x1="0" y1="1" x2="1" y2="0"><stop offset="0" stop-color="#4F8BF7"></stop><stop offset="0.5" stop-color="#EA4335"></stop><stop offset="1" stop-color="#FBBC04"></stop></linearGradient></defs><rect x="0.25" y="0.25" width="23.5" height="23.5" rx="6.7" fill="#171717" stroke="var(--nc-line, #3f3f46)" stroke-width="0.5"></rect><path d="M5.3 18.7 12 5.3l6.7 13.4M8.8 14.1h6.4" fill="none" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"></path></svg>`);
var root_5$2 = /* @__PURE__ */ from_html(`<span class="mark letter svelte-1vbdbgh" aria-hidden="true"> </span>`);
var $$css$4 = {
	hash: "svelte-1vbdbgh",
	code: ".mark.svelte-1vbdbgh {flex-shrink:0;display:block;}.laptop.svelte-1vbdbgh {fill:none;stroke:currentColor;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round;}.letter.svelte-1vbdbgh {display:grid;place-items:center;border-radius:28%;background:color-mix(in srgb, currentColor 20%, transparent);font-weight:700;line-height:1;}"
};
function AgentMark($$anchor, $$props) {
	push($$props, true);
	append_styles$1($$anchor, $$css$4);
	let size = prop($$props, "size", 3, 16), local = prop($$props, "local", 3, false), letter = prop($$props, "letter", 3, false);
	const id = `nook-mark-${next++}`;
	const antigravity = /* @__PURE__ */ user_derived(() => $$props.name.toLowerCase().includes("antigravity"));
	const brand = /* @__PURE__ */ user_derived(() => local() || get(antigravity) ? void 0 : brandFor($$props.name));
	const fill = /* @__PURE__ */ user_derived(() => get(brand) ? brandFill(get(brand)) : null);
	var fragment = comment();
	var node = first_child(fragment);
	var consequent = ($$anchor) => {
		var svg = root$3();
		template_effect(() => {
			set_attribute(svg, "width", size());
			set_attribute(svg, "height", size());
		});
		append($$anchor, svg);
	};
	var consequent_2 = ($$anchor) => {
		var svg_1 = root_3$2();
		var node_1 = child(svg_1);
		var consequent_1 = ($$anchor) => {
			var defs = root_1$2();
			var linearGradient = child(defs);
			var stop = child(linearGradient);
			var stop_1 = sibling(stop);
			reset(linearGradient);
			reset(defs);
			template_effect(() => {
				set_attribute(linearGradient, "id", id);
				set_attribute(stop, "stop-color", get(fill)[0]);
				set_attribute(stop_1, "stop-color", get(fill)[1]);
			});
			append($$anchor, defs);
		};
		var d_1 = /* @__PURE__ */ user_derived(() => Array.isArray(get(fill)));
		if_block(node_1, ($$render) => {
			if (get(d_1)) $$render(consequent_1);
		});
		each(sibling(node_1), 17, () => brandPaths[get(brand)] ?? [], index, ($$anchor, d) => {
			var path = root_2$2();
			template_effect(($0) => {
				set_attribute(path, "d", get(d));
				set_attribute(path, "fill", $0);
			}, [() => Array.isArray(get(fill)) ? `url(#${id})` : get(fill) ?? "currentColor"]);
			append($$anchor, path);
		});
		reset(svg_1);
		template_effect(() => {
			set_attribute(svg_1, "width", size());
			set_attribute(svg_1, "height", size());
		});
		append($$anchor, svg_1);
	};
	var consequent_3 = ($$anchor) => {
		var svg_2 = root_4$2();
		var defs_1 = child(svg_2);
		var linearGradient_1 = only_child(defs_1);
		var path_1 = sibling(defs_1, 2);
		reset(svg_2);
		template_effect(() => {
			set_attribute(svg_2, "width", size());
			set_attribute(svg_2, "height", size());
			set_attribute(linearGradient_1, "id", id);
			set_attribute(path_1, "stroke", `url(#${id})`);
		});
		append($$anchor, svg_2);
	};
	var consequent_4 = ($$anchor) => {
		var span = root_5$2();
		let styles;
		var text = only_child(span, true);
		template_effect(($0) => {
			styles = set_style(span, "", styles, {
				width: `${size() ?? ""}px`,
				height: `${size() ?? ""}px`,
				"font-size": `${size() * .52}px`
			});
			set_text(text, $0);
		}, [() => $$props.name.slice(0, 1).toUpperCase()]);
		append($$anchor, span);
	};
	if_block(node, ($$render) => {
		if (local()) $$render(consequent);
		else if (get(brand)) $$render(consequent_2, 1);
		else if (get(antigravity)) $$render(consequent_3, 2);
		else if (letter()) $$render(consequent_4, 3);
	});
	append($$anchor, fragment);
	pop();
}
// src/ModelPicker.svelte
var pickers = 0;
var root_1$1 = /* @__PURE__ */ from_html(`<span class="mp-rail-line svelte-9tg97k" aria-hidden="true"></span>`);
var root_2$1 = /* @__PURE__ */ from_html(`<span class="mp-in-use svelte-9tg97k" aria-hidden="true"></span>`);
var root_3$1 = /* @__PURE__ */ from_html(`<!> <button type="button"><!> <!></button>`, 1);
var root_4$1 = /* @__PURE__ */ from_html(`<div class="mp-header svelte-9tg97k"> </div>`);
var root_5$1 = /* @__PURE__ */ from_html(`<button type="button" role="option"><!> <span class="mp-title svelte-9tg97k"> </span></button>`);
var root_6$1 = /* @__PURE__ */ from_html(`<p class="mp-empty svelte-9tg97k"> </p>`);
var root_7$1 = /* @__PURE__ */ from_html(`<div class="mp-panel svelte-9tg97k" role="dialog"><div class="mp-rail svelte-9tg97k"></div> <div class="mp-column svelte-9tg97k"><!> <label class="mp-search svelte-9tg97k"><svg viewBox="0 0 16 16" aria-hidden="true" class="svelte-9tg97k"><circle cx="7" cy="7" r="4.5"></circle><path d="m10.5 10.5 3 3"></path></svg> <input type="search" role="combobox" aria-expanded="true" aria-autocomplete="list" class="svelte-9tg97k"/></label> <div class="mp-list svelte-9tg97k" role="listbox"></div></div></div>`);
var root_8$1 = /* @__PURE__ */ from_html(`<div class="mp svelte-9tg97k"><button type="button" aria-haspopup="dialog"><!> <span class="mp-label svelte-9tg97k"> </span> <svg class="mp-chevron svelte-9tg97k" viewBox="0 0 16 16" aria-hidden="true"><path d="m4.5 6.5 3.5 3.5 3.5-3.5"></path></svg></button> <!></div>`);
var $$css$3 = {
	hash: "svelte-9tg97k",
	code: "\n  /* Class names start with mp-: the surface's own stylesheet (the extension's side panel) has its own .menu, .empty… */.mp.svelte-9tg97k {position:relative;min-width:0;}.mp.svelte-9tg97k button:where(.svelte-9tg97k) {margin:0;border:0;font-family:inherit;font-weight:inherit;line-height:inherit;cursor:pointer;transition:background-color 0.15s ease, color 0.15s ease;}.mp-chip.svelte-9tg97k {display:flex;align-items:center;gap:6px;max-width:100%;min-width:0;height:28px;padding:0 8px;border-radius:var(--nc-control-radius, 8px);background:transparent;color:var(--nc-faint, #62626c);font-size:13px;white-space:nowrap;}.mp-chip.svelte-9tg97k:hover:not(:disabled), .mp-chip.open.svelte-9tg97k {background:var(--nc-hover, #f4f4f5);color:var(--nc-text, #27272a);}.mp-chip.svelte-9tg97k:disabled {cursor:default;opacity:0.6;}.mp-chip.svelte-9tg97k:focus-visible {outline:2px solid var(--nc-accent, #1e1e22);outline-offset:2px;}.mp-label.svelte-9tg97k {overflow:hidden;text-overflow:ellipsis;min-width:0;}.mp-chevron.svelte-9tg97k {flex-shrink:0;width:12px;height:12px;fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round;}.mp-panel.svelte-9tg97k {position:absolute;bottom:calc(100% + 8px);z-index:20;display:flex;align-items:stretch;padding:4px;border:1px solid var(--nc-line, #e4e4e7);border-radius:var(--nc-menu-radius, 12px);background:var(--nc-menu, var(--nc-surface, #ffffff));color:var(--nc-text, #27272a);box-shadow:0 12px 32px rgb(0 0 0 / 0.28);overflow:hidden;}.mp-rail.svelte-9tg97k {flex-shrink:0;display:flex;flex-direction:column;gap:4px;width:44px;padding:6px;background:color-mix(in srgb, var(--nc-text, #27272a) 3%, transparent);border-right:1px solid var(--nc-line, #e4e4e7);}.mp-rail-line.svelte-9tg97k {align-self:center;width:18px;height:1px;margin:2px 0;background:var(--nc-line-focus, #d4d4d8);}.mp-place.svelte-9tg97k {position:relative;display:grid;place-items:center;width:32px;height:32px;padding:0;border-radius:var(--nc-control-radius, 8px);background:transparent;color:var(--nc-text, #27272a);}.mp-place.svelte-9tg97k:hover {background:var(--nc-hover, #f4f4f5);}.mp-place.shown.svelte-9tg97k {background:color-mix(in srgb, var(--nc-text, #27272a) 8%, transparent);}.mp-place.svelte-9tg97k:focus-visible {outline:2px solid var(--nc-accent, #1e1e22);outline-offset:-2px;}.mp-in-use.svelte-9tg97k {position:absolute;top:4px;right:4px;width:4px;height:4px;border-radius:50%;background:color-mix(in srgb, var(--nc-text, #27272a) 70%, transparent);}.mp-column.svelte-9tg97k {flex:1;min-width:0;display:flex;flex-direction:column;padding:0 4px;}.mp-header.svelte-9tg97k {padding:8px 8px 4px;color:var(--nc-faint, #62626c);font-size:11.5px;font-weight:500;}.mp-search.svelte-9tg97k {display:flex;align-items:center;gap:6px;padding:6px 8px;border-bottom:1px solid var(--nc-line, #e4e4e7);color:var(--nc-faint, #62626c);}.mp-search.svelte-9tg97k svg:where(.svelte-9tg97k) {flex-shrink:0;width:13px;height:13px;fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;}.mp-search.svelte-9tg97k input:where(.svelte-9tg97k) {flex:1;min-width:0;margin:0;padding:0;border:0;background:transparent;color:var(--nc-text, #27272a);font:inherit;font-size:13px;outline:none;}.mp-search.svelte-9tg97k input:where(.svelte-9tg97k)::placeholder {color:var(--nc-faint, #62626c);}.mp-search.svelte-9tg97k input:where(.svelte-9tg97k)::-webkit-search-cancel-button {display:none;}.mp-list.svelte-9tg97k {max-height:240px;overflow-y:auto;padding:4px 0;}.mp-row.svelte-9tg97k {display:flex;align-items:center;gap:8px;width:100%;min-height:30px;padding:6px 8px;border-radius:var(--nc-chip-radius, 6px);background:transparent;color:var(--nc-text, #27272a);font-size:13px;text-align:left;}.mp-row.chosen.svelte-9tg97k {background:color-mix(in srgb, var(--nc-text, #27272a) 8%, transparent);}.mp-row.active.svelte-9tg97k {background:var(--nc-hover, #f4f4f5);}.mp-row.svelte-9tg97k:focus-visible {outline:2px solid var(--nc-accent, #1e1e22);outline-offset:-2px;}.mp-title.svelte-9tg97k {flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}.mp-empty.svelte-9tg97k {margin:0;padding:10px;color:var(--nc-faint, #62626c);font-size:12px;}"
};
function ModelPicker($$anchor, $$props) {
	push($$props, true);
	append_styles$1($$anchor, $$css$3);
	let group = prop($$props, "group", 3, ""), disabled = prop($$props, "disabled", 3, false);
	/** The menu opens: the surface can fetch the newest list. */
	/** The panel's width on the Mac (`ModelPickerStyle.width`), and the room it keeps from the window's edges. */
	const width = 340;
	/** Ties the search field to its list and the row the arrow keys are on, for assistive technology. */
	const listID = `nook-model-list-${pickers++}`;
	const margin = 12;
	let open = /* @__PURE__ */ state(false);
	let query = /* @__PURE__ */ state("");
	let highlight = /* @__PURE__ */ state(0);
	/** The place looked at; null is the place in use. */
	let shownPlace = /* @__PURE__ */ state(null);
	/** How far the panel moves left or right of the chip to stay inside the window. */
	let shift = /* @__PURE__ */ state(-4);
	let root = /* @__PURE__ */ state(void 0);
	let search = /* @__PURE__ */ state(void 0);
	let list = /* @__PURE__ */ state(void 0);
	const chosen = /* @__PURE__ */ user_derived(() => $$props.choices.find((c) => c.chosen));
	/** The places in the rail: this Mac first, then the agents in the order Nook lists them. */
	const places = /* @__PURE__ */ user_derived(() => {
		const out = [];
		for (const choice of $$props.choices) if (!out.some((p) => p.name === choice.group)) out.push({
			name: choice.group,
			local: !!choice.local
		});
		return [...out.filter((p) => p.local), ...out.filter((p) => !p.local)];
	});
	const inUse = /* @__PURE__ */ user_derived(() => get(chosen)?.group ?? get(places).find((p) => p.name === group())?.name ?? get(places)[0]?.name ?? "");
	const current = /* @__PURE__ */ user_derived(() => get(places).find((p) => p.name === (get(shownPlace) ?? get(inUse))) ?? get(places)[0]);
	const rows = /* @__PURE__ */ user_derived(() => {
		if (!get(current)) return [];
		const words = get(query).trim().toLowerCase().split(/\s+/).filter(Boolean);
		return $$props.choices.filter((c) => c.group === get(current).name && words.every((w) => c.title.toLowerCase().includes(w)));
	});
	const active = /* @__PURE__ */ user_derived(() => get(rows).length ? Math.min(get(highlight), get(rows).length - 1) : -1);
	/** The chip's mark: the agent's logo, or the local model's maker (a laptop when it has none). */
	const chipLocal = /* @__PURE__ */ user_derived(() => !!get(chosen)?.local && !brandFor($$props.label));
	const chipMark = /* @__PURE__ */ user_derived(() => get(chosen)?.local ? $$props.label : group() || $$props.label);
	function place() {
		const rect = get(root)?.getBoundingClientRect();
		if (!rect) return;
		const room = window.innerWidth - margin;
		const panel = Math.min(width, window.innerWidth - 24);
		set(shift, Math.max(margin - rect.left, Math.min(-4, room - panel - rect.left)), true);
	}
	function toggle() {
		set(open, !get(open));
		set(query, "");
		set(highlight, 0);
		set(shownPlace, null);
		if (get(open)) {
			$$props.onopen?.();
			place();
			queueMicrotask(() => get(search)?.focus());
		}
	}
	function show(name) {
		set(shownPlace, name, true);
		set(query, "");
		set(highlight, 0);
		get(search)?.focus();
	}
	function choose(choice) {
		if (!choice) return;
		set(open, false);
		if (!choice.chosen) $$props.onchoose(choice.id);
	}
	function step(by) {
		if (!get(rows).length) return;
		set(highlight, (get(active) + by + get(rows).length) % get(rows).length);
		queueMicrotask(() => get(list)?.querySelector(`[data-index="${get(highlight)}"]`)?.scrollIntoView({ block: "nearest" }));
	}
	function key(e) {
		if (e.isComposing || e.keyCode === 229 || e.metaKey || e.ctrlKey || e.altKey) return;
		if (e.key === "ArrowDown") step(1);
		else if (e.key === "ArrowUp") step(-1);
		else if (e.key === "Enter") choose(get(rows)[get(active)]);
		else return;
		e.preventDefault();
	}
	var div = root_8$1();
	event("click", $window, (e) => get(open) && !get(root)?.contains(e.target) && set(open, false));
	event("keydown", $window, (e) => get(open) && e.key === "Escape" && (set(open, false), e.stopPropagation()));
	event("resize", $window, () => get(open) && place());
	var button = child(div);
	let classes;
	var node = child(button);
	{
		let $0 = /* @__PURE__ */ user_derived(() => !get(chosen)?.local);
		AgentMark(node, {
			get name() {
				return get(chipMark);
			},
			get local() {
				return get(chipLocal);
			},
			get letter() {
				return get($0);
			},
			size: 15
		});
	}
	var text = only_child(sibling(node, 2), true);
	next$1(2);
	reset(button);
	var node_1 = sibling(button, 2);
	var consequent_3 = ($$anchor) => {
		var div_1 = root_7$1();
		let styles;
		var div_2 = child(div_1);
		each(div_2, 23, () => get(places), (p) => p.name, ($$anchor, p, i) => {
			var fragment = root_3$1();
			var node_2 = first_child(fragment);
			var consequent = ($$anchor) => {
				append($$anchor, root_1$1());
			};
			if_block(node_2, ($$render) => {
				if (get(i) > 0 && get(places)[get(i) - 1].local && !get(p).local) $$render(consequent);
			});
			var button_1 = sibling(node_2, 2);
			let classes_1;
			var node_3 = child(button_1);
			AgentMark(node_3, {
				get name() {
					return get(p).name;
				},
				get local() {
					return get(p).local;
				},
				letter: true,
				size: 18
			});
			var node_4 = sibling(node_3, 2);
			var consequent_1 = ($$anchor) => {
				append($$anchor, root_2$1());
			};
			if_block(node_4, ($$render) => {
				if (get(p).name === get(inUse) && get(p) !== get(current)) $$render(consequent_1);
			});
			reset(button_1);
			template_effect(() => {
				classes_1 = set_class(button_1, 1, "mp-place svelte-9tg97k", null, classes_1, { shown: get(p) === get(current) });
				set_attribute(button_1, "title", get(p).name);
				set_attribute(button_1, "aria-label", get(p).name);
				set_attribute(button_1, "aria-pressed", get(p) === get(current));
			});
			delegated("click", button_1, () => show(get(p).name));
			append($$anchor, fragment);
		});
		reset(div_2);
		var div_3 = sibling(div_2, 2);
		var node_5 = child(div_3);
		var consequent_2 = ($$anchor) => {
			var div_4 = root_4$1();
			var text_1 = only_child(div_4, true);
			template_effect(() => set_text(text_1, get(current).name));
			append($$anchor, div_4);
		};
		if_block(node_5, ($$render) => {
			if (get(current)) $$render(consequent_2);
		});
		var label_1 = sibling(node_5, 2);
		var input = sibling(child(label_1), 2);
		remove_input_defaults(input);
		bind_this(input, ($$value) => set(search, $$value), () => get(search));
		reset(label_1);
		var div_5 = sibling(label_1, 2);
		each(div_5, 23, () => get(rows), (choice) => choice.id, ($$anchor, choice, index) => {
			var button_2 = root_5$1();
			let classes_2;
			var node_6 = child(button_2);
			{
				let $0 = /* @__PURE__ */ user_derived(() => get(choice).local ? get(choice).title : brandFor(get(choice).title) ? get(choice).title : get(choice).group);
				AgentMark(node_6, {
					get name() {
						return get($0);
					},
					size: 14
				});
			}
			var text_2 = only_child(sibling(node_6, 2), true);
			reset(button_2);
			template_effect(() => {
				classes_2 = set_class(button_2, 1, "mp-row svelte-9tg97k", null, classes_2, {
					chosen: get(choice).chosen,
					active: get(index) === get(active)
				});
				set_attribute(button_2, "data-index", get(index));
				set_attribute(button_2, "id", `${listID}-${get(index) ?? ""}`);
				set_attribute(button_2, "aria-selected", get(index) === get(active));
				set_attribute(button_2, "aria-checked", !!get(choice).chosen);
				set_text(text_2, get(choice).title);
			});
			event("mouseenter", button_2, () => set(highlight, get(index), true));
			delegated("click", button_2, () => choose(get(choice)));
			append($$anchor, button_2);
		}, ($$anchor) => {
			var p_1 = root_6$1();
			var text_3 = only_child(p_1, true);
			template_effect(() => set_text(text_3, $$props.texts.empty));
			append($$anchor, p_1);
		});
		reset(div_5);
		bind_this(div_5, ($$value) => set(list, $$value), () => get(list));
		reset(div_3);
		reset(div_1);
		template_effect(() => {
			set_attribute(div_1, "aria-label", $$props.texts.button);
			styles = set_style(div_1, "", styles, {
				left: `${get(shift) ?? ""}px`,
				width: "min(340px, calc(100vw - 24px))"
			});
			set_attribute(input, "aria-controls", listID);
			set_attribute(input, "aria-activedescendant", get(active) >= 0 ? `${listID}-${get(active)}` : void 0);
			set_attribute(input, "placeholder", $$props.texts.search);
			set_attribute(input, "aria-label", $$props.texts.search);
			set_attribute(div_5, "id", listID);
			set_attribute(div_5, "aria-label", get(current)?.name);
		});
		delegated("input", input, () => set(highlight, 0));
		delegated("keydown", input, key);
		bind_value(input, () => get(query), ($$value) => set(query, $$value));
		append($$anchor, div_1);
	};
	if_block(node_1, ($$render) => {
		if (get(open)) $$render(consequent_3);
	});
	reset(div);
	bind_this(div, ($$value) => set(root, $$value), () => get(root));
	template_effect(() => {
		classes = set_class(button, 1, "mp-chip svelte-9tg97k", null, classes, { open: get(open) });
		set_attribute(button, "title", $$props.texts.button);
		set_attribute(button, "aria-expanded", get(open));
		button.disabled = disabled();
		set_text(text, group() ? `${group()} · ${$$props.label}` : $$props.label);
	});
	delegated("click", button, toggle);
	append($$anchor, div);
	pop();
}
delegate([
	"click",
	"input",
	"keydown"
]);
var Draft = class {
	readDocument;
	#text = /* @__PURE__ */ state("");
	get text() {
		return get(this.#text);
	}
	set text(value) {
		set(this.#text, value, true);
	}
	#images = /* @__PURE__ */ state(proxy([]));
	get images() {
		return get(this.#images);
	}
	set images(value) {
		set(this.#images, value, true);
	}
	#attachment = /* @__PURE__ */ state(null);
	get attachment() {
		return get(this.#attachment);
	}
	set attachment(value) {
		set(this.#attachment, value, true);
	}
	#reading = /* @__PURE__ */ state(false);
	get reading() {
		return get(this.#reading);
	}
	set reading(value) {
		set(this.#reading, value, true);
	}
	#fileError = /* @__PURE__ */ state(null);
	get fileError() {
		return get(this.#fileError);
	}
	set fileError(value) {
		set(this.#fileError, value, true);
	}
	#picking = /* @__PURE__ */ state(false);
	get picking() {
		return get(this.#picking);
	}
	set picking(value) {
		set(this.#picking, value, true);
	}
	constructor(readDocument = null) {
		this.readDocument = readDocument;
	}
	/** Whether documents (not only pictures) can be attached here. */
	get readsDocuments() {
		return this.readDocument !== null;
	}
	/** What a badge counts: files waiting in the field. */
	get files() {
		return this.images.length + (this.attachment || this.reading ? 1 : 0);
	}
	get empty() {
		return !this.text.trim() && !this.attachment && !this.images.length;
	}
	addImage(mediaType, base64) {
		if (this.images.length >= 10) return;
		this.images = [...this.images, {
			mediaType,
			base64,
			url: `data:${mediaType};base64,${base64}`
		}];
	}
	removeImage(index) {
		this.images = this.images.filter((_, i) => i !== index);
	}
	clear() {
		this.text = "";
		this.images = [];
		this.attachment = null;
	}
	/** Files chosen, dropped or pasted: pictures join the strip, a document is read when this surface can. */
	async addFiles(files) {
		this.fileError = null;
		for (const file of Array.from(files)) {
			if (file.type.startsWith("image/")) {
				this.addImage(file.type, await fileBase64(file));
				continue;
			}
			if (!this.readDocument) continue;
			this.reading = true;
			try {
				this.attachment = await this.readDocument(file.name, await fileBase64(file));
			} catch (e) {
				this.fileError = String(e);
			} finally {
				this.reading = false;
			}
		}
	}
};
/** A file's contents as base64, without the `data:` prefix. */
function fileBase64(file) {
	return new Promise((resolve, reject) => {
		const reader = new FileReader();
		reader.onload = () => resolve(String(reader.result).split(",")[1] ?? "");
		reader.onerror = () => reject(reader.error);
		reader.readAsDataURL(file);
	});
}
// ../../apps/browser-extension/composer/PanelComposer.svelte
var root$2 = /* @__PURE__ */ from_html(`<div class="panel-composer svelte-1dv7v2j"><!></div>`);
var $$css$2 = {
	hash: "svelte-1dv7v2j",
	code: "\n  /* The shared composer in the panel's tokens (sidepanel.css), which follow the look Nook sends. */.panel-composer.svelte-1dv7v2j {--nc-surface: var(--composer);--nc-surface-focus: var(--composer);--nc-line: var(--field-stroke);--nc-line-focus: var(--line2);--nc-radius: var(--radius-composer);--nc-control-radius: var(--radius-control);--nc-chip-radius: var(--radius-chip);--nc-menu: var(--surface);--nc-menu-radius: var(--radius-panel);--nc-pad: var(--space-md) var(--space-md) var(--space-md) var(--space-lg);--nc-shadow: 0 1px 0 color-mix(in srgb, var(--paper) 4%, transparent), 0 8px 24px rgb(0 0 0 / 0.12);--nc-text: var(--paper);--nc-faint: var(--text-tertiary);--nc-hover: var(--row-hover);--nc-accent: var(--accent);--nc-on-accent: var(--on-accent);--nc-accent-hover: var(--accent-hover);--nc-disabled: var(--smoke);--nc-stop: var(--paper);--nc-on-stop: var(--canvas);--nc-error: var(--coral);font:var(--body)/1.45 var(--sans);}"
};
function PanelComposer($$anchor, $$props) {
	push($$props, true);
	append_styles$1($$anchor, $$css$2);
	const t = (key) => globalThis.chrome?.i18n?.getMessage(key) || key;
	const draft = new Draft();
	let composer = /* @__PURE__ */ state(void 0);
	function focus() {
		get(composer)?.focus();
	}
	/** Puts a question in the field (a suggestion), ready to send or change. */
	function fill(text) {
		draft.text = text;
		get(composer)?.focus();
	}
	const texts = {
		placeholder: t("askPlaceholder"),
		field: t("messageField"),
		send: t("send"),
		stop: t("stopAnswer"),
		attach: t("attachImages"),
		removeImage: t("removeImage")
	};
	const modelTexts = {
		button: t("modelChip"),
		search: t("modelSearch"),
		empty: t("modelEmpty")
	};
	function send({ text, images }) {
		$$props.onsend(text || t("imageQuestion"), images);
	}
	var $$exports = {
		focus,
		fill
	};
	var div = root$2();
	var node = child(div);
	{
		const controls = ($$anchor) => {
			var fragment = comment();
			var node_1 = first_child(fragment);
			var consequent = ($$anchor) => {
				{
					let $0 = /* @__PURE__ */ user_derived(() => !$$props.panel.connected);
					ModelPicker($$anchor, {
						get label() {
							return $$props.panel.brain.label;
						},
						get group() {
							return $$props.panel.brain.group;
						},
						get choices() {
							return $$props.panel.brain.choices;
						},
						get texts() {
							return modelTexts;
						},
						get disabled() {
							return get($0);
						},
						get onopen() {
							return $$props.onbrain;
						},
						get onchoose() {
							return $$props.onchoosebrain;
						}
					});
				}
			};
			if_block(node_1, ($$render) => {
				if ($$props.panel.brain) $$render(consequent);
			});
			append($$anchor, fragment);
		};
		let $0 = /* @__PURE__ */ user_derived(() => !$$props.panel.connected);
		let $1 = /* @__PURE__ */ user_derived(() => $$props.panel.canStop ? $$props.onstop : void 0);
		bind_this(Composer(node, {
			get draft() {
				return draft;
			},
			get texts() {
				return texts;
			},
			get busy() {
				return $$props.panel.busy;
			},
			get disabled() {
				return get($0);
			},
			get history() {
				return $$props.panel.history;
			},
			get historyKey() {
				return $$props.panel.conversation;
			},
			escapeStops: true,
			onsend: send,
			get onstop() {
				return get($1);
			},
			controls,
			$$slots: { controls: true }
		}), ($$value) => set(composer, $$value, true), () => get(composer));
	}
	reset(div);
	append($$anchor, div);
	return pop($$exports);
}
// src/markdown.ts
var englishTexts = {
	copy: "Copy",
	copyTitle: "Copy code"
};
function escapeHtml(text) {
	return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}
function inline(text, texts) {
	let out = escapeHtml(text);
	const codes = [];
	out = out.replace(/`([^`]+)`/g, (_m, code) => {
		codes.push(`<code>${code}</code>`);
		return `\u0000${codes.length - 1}\u0000`;
	});
	const links = [];
	out = out.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>").replace(/(^|[^*])\*([^*\s][^*]*)\*/g, "$1<em>$2</em>").replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, (_m, label, url) => {
		links.push(`<a href="${url}" data-external>${label}</a>`);
		return `\u0001${links.length - 1}\u0001`;
	});
	if (texts.citation) out = out.replace(/((?:\[\d{1,3}(?:\s*,\s*\d{1,3})*\])+)(?!\()/g, (_m, group) => {
		const nums = [...group.matchAll(/\d{1,3}/g)].map((m) => Number(m[0]));
		return texts.citation(nums);
	});
	else out = out.replace(/\[(\d{1,2})\]/g, "<sup class=\"cite\" data-cite=\"$1\">$1</sup>");
	return out.replace(/\u0001(\d+)\u0001/g, (_m, i) => links[Number(i)]).replace(/\u0000(\d+)\u0000/g, (_m, i) => codes[Number(i)]);
}
function isTableDivider(line) {
	return /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(line);
}
function cells(line) {
	return line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim());
}
function renderMarkdown(source, texts = englishTexts) {
	const lines = source.replace(/\r\n/g, "\n").split("\n");
	const html = [];
	let i = 0;
	while (i < lines.length) {
		const line = lines[i];
		const fence = line.match(/^```\s*([\w+-]*)/);
		if (fence) {
			const body = [];
			i++;
			while (i < lines.length && !lines[i].startsWith("```")) body.push(lines[i++]);
			i++;
			html.push(`<div class="code-block"><button type="button" class="copy-code" data-copy-code title="${escapeHtml(texts.copyTitle)}">${escapeHtml(texts.copy)}</button><pre><code${fence[1] ? ` data-lang="${escapeHtml(fence[1])}"` : ""}>${escapeHtml(body.join("\n"))}</code></pre></div>`);
			continue;
		}
		const heading = line.match(/^(#{1,4})\s+(.*)$/);
		if (heading) {
			const level = Math.min(heading[1].length + 2, 6);
			html.push(`<h${level}>${inline(heading[2], texts)}</h${level}>`);
			i++;
			continue;
		}
		if (line.includes("|") && i + 1 < lines.length && isTableDivider(lines[i + 1])) {
			const head = cells(line);
			i += 2;
			const rows = [];
			while (i < lines.length && lines[i].includes("|") && lines[i].trim()) rows.push(cells(lines[i++]));
			html.push(`<table><thead><tr>${head.map((c) => `<th>${inline(c, texts)}</th>`).join("")}</tr></thead><tbody>` + rows.map((r) => `<tr>${r.map((c) => `<td>${inline(c, texts)}</td>`).join("")}</tr>`).join("") + "</tbody></table>");
			continue;
		}
		if (/^\s*([-*•]|\d+[.)])\s+/.test(line)) {
			const ordered = /^\s*\d+[.)]/.test(line);
			const items = [];
			while (i < lines.length && /^\s*([-*•]|\d+[.)])\s+/.test(lines[i])) {
				items.push(lines[i].replace(/^\s*([-*•]|\d+[.)])\s+/, ""));
				i++;
			}
			const tag = ordered ? "ol" : "ul";
			html.push(`<${tag}>${items.map((it) => `<li>${inline(it, texts)}</li>`).join("")}</${tag}>`);
			continue;
		}
		if (/^>\s?/.test(line)) {
			const quote = [];
			while (i < lines.length && /^>\s?/.test(lines[i])) quote.push(lines[i++].replace(/^>\s?/, ""));
			html.push(`<blockquote>${inline(quote.join(" "), texts)}</blockquote>`);
			continue;
		}
		if (!line.trim()) {
			i++;
			continue;
		}
		const para = [];
		while (i < lines.length && lines[i].trim() && !/^(```|#{1,4}\s|>|\s*([-*•]|\d+[.)])\s)/.test(lines[i])) {
			if (lines[i].includes("|") && i + 1 < lines.length && isTableDivider(lines[i + 1])) break;
			para.push(lines[i++]);
		}
		if (para.length) html.push(`<p>${para.map((p) => inline(p, texts)).join("<br>")}</p>`);
		else i++;
	}
	return html.join("");
}
// src/Transcript.svelte
var root$1 = /* @__PURE__ */ from_html(`<span class="time svelte-xmynmn"> </span>`);
var root_1 = /* @__PURE__ */ from_html(`<button type="button" class="act svelte-xmynmn"><svg viewBox="0 0 16 16" aria-hidden="true" class="svelte-xmynmn"><path d="M3 8a5 5 0 1 0 1.5-3.6" class="svelte-xmynmn"></path><path d="M3 2.5v2.8h2.8" class="svelte-xmynmn"></path></svg></button>`);
var root_2 = /* @__PURE__ */ from_svg(`<svg viewBox="0 0 16 16" aria-hidden="true" class="svelte-xmynmn"><path d="m3.5 8.5 3 3 6-7" class="svelte-xmynmn"></path></svg>`);
var root_3 = /* @__PURE__ */ from_svg(`<svg viewBox="0 0 16 16" aria-hidden="true" class="svelte-xmynmn"><rect x="5" y="5" width="8" height="8" rx="1.5" class="svelte-xmynmn"></rect><path d="M11 3.5V3a1 1 0 0 0-1-1H4a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h.5" class="svelte-xmynmn"></path></svg>`);
var root_4 = /* @__PURE__ */ from_html(`<button type="button" class="act svelte-xmynmn"><!></button>`);
var root_5 = /* @__PURE__ */ from_html(`<div class="you-row svelte-xmynmn" data-role="you"><div class="actions svelte-xmynmn"><!> <!> <!></div> <div class="you svelte-xmynmn"> </div></div>`);
var root_6 = /* @__PURE__ */ from_svg(`<svg viewBox="0 0 16 16" class="svelte-xmynmn"><path d="m4 8.5 2.5 2.5 5.5-6" class="svelte-xmynmn"></path></svg>`);
var root_7 = /* @__PURE__ */ from_html(`<span class="spin svelte-xmynmn"></span>`);
var root_8 = /* @__PURE__ */ from_html(`<li><span class="mark svelte-xmynmn" aria-hidden="true"><!></span> <span class="svelte-xmynmn"> </span></li>`);
var root_9 = /* @__PURE__ */ from_html(`<ul class="tasks svelte-xmynmn"></ul>`);
var root_10 = /* @__PURE__ */ from_html(`<div class="prose svelte-xmynmn"></div>`);
var root_11 = /* @__PURE__ */ from_html(`<span class="dots svelte-xmynmn"><i class="svelte-xmynmn"></i><i class="svelte-xmynmn"></i><i class="svelte-xmynmn"></i></span>`);
var root_12 = /* @__PURE__ */ from_html(`<div class="status shimmer svelte-xmynmn"> </div>`);
var root_13 = /* @__PURE__ */ from_html(`<span class="badge svelte-xmynmn" aria-hidden="true">!</span>`);
var root_14 = /* @__PURE__ */ from_html(`<span class="source-detail svelte-xmynmn"> </span>`);
var root_15 = /* @__PURE__ */ from_html(`<li><span class="state svelte-xmynmn" aria-hidden="true"></span> <span class="source-title svelte-xmynmn"> </span> <!></li>`);
var root_16 = /* @__PURE__ */ from_html(`<a class="svelte-xmynmn"> </a>`);
var root_17 = /* @__PURE__ */ from_html(`<span class="source-title svelte-xmynmn"> </span>`);
var root_18 = /* @__PURE__ */ from_html(`<li class="reference svelte-xmynmn"><span class="number svelte-xmynmn"> </span> <!></li>`);
var root_19 = /* @__PURE__ */ from_html(`<ul class="source-list svelte-xmynmn"><!> <!></ul>`);
var root_20 = /* @__PURE__ */ from_html(`<div class="sources svelte-xmynmn"><button type="button"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="m6 4 4 4-4 4" class="svelte-xmynmn"></path></svg> <span> </span> <!></button> <!></div>`);
var root_21 = /* @__PURE__ */ from_html(`<div class="note svelte-xmynmn"> </div>`);
var root_22 = /* @__PURE__ */ from_html(`<div class="note on-mac svelte-xmynmn"> </div>`);
var root_23 = /* @__PURE__ */ from_html(`<div><!> <!></div>`);
var root_24 = /* @__PURE__ */ from_html(`<div data-role="nook"><!> <!> <!> <!> <!> <!> <!></div>`);
var root_25 = /* @__PURE__ */ from_html(`<div class="nook-transcript svelte-xmynmn"></div>`);
var $$css$1 = {
	hash: "svelte-xmynmn",
	code: "\n  /* Every color comes from the surface (`--nt-*`); the fallbacks are Nook's own dark theme. */.nook-transcript.svelte-xmynmn {display:flex;flex-direction:column;gap:18px;min-width:0;color:var(--nt-text, #ececef);}\n  /* Your question with, on hover, its time and what you can do with it to its left. */.you-row.svelte-xmynmn {align-self:stretch;display:flex;align-items:center;justify-content:flex-end;gap:4px;min-width:0;}.you.svelte-xmynmn {max-width:85%;padding:8px 13px;border-radius:var(--nt-bubble-radius, 16px);background:var(--nt-bubble, #26262b);color:var(--nt-text, #ececef);white-space:pre-wrap;overflow-wrap:anywhere;}.nook.svelte-xmynmn {display:flex;flex-direction:column;gap:8px;min-width:0;}.failed.svelte-xmynmn .prose:where(.svelte-xmynmn) {color:var(--nt-error, #ff6b5e);}.prose.svelte-xmynmn {overflow-wrap:anywhere;line-height:1.55;}.prose.svelte-xmynmn p {margin:0 0 10px;}.prose.svelte-xmynmn p:last-child, .prose.svelte-xmynmn ul:last-child, .prose.svelte-xmynmn ol:last-child {margin-bottom:0;}.prose.svelte-xmynmn h3, .prose.svelte-xmynmn h4, .prose.svelte-xmynmn h5, .prose.svelte-xmynmn h6 {margin:14px 0 6px;font-size:1em;font-weight:600;}.prose.svelte-xmynmn h3:first-child, .prose.svelte-xmynmn h4:first-child {margin-top:0;}.prose.svelte-xmynmn ul, .prose.svelte-xmynmn ol {margin:0 0 10px;padding-left:20px;}.prose.svelte-xmynmn li {margin:3px 0;}.prose.svelte-xmynmn li::marker {color:var(--nt-faint, #8b8b94);}.prose.svelte-xmynmn strong {font-weight:600;}.prose.svelte-xmynmn a {color:var(--nt-accent, #8ab4ff);text-decoration:none;}.prose.svelte-xmynmn a:hover {text-decoration:underline;}.prose.svelte-xmynmn code {font-family:var(--nt-mono, ui-monospace, \"SF Mono\", Menlo, monospace);font-size:0.9em;padding:1px 5px;border-radius:5px;background:var(--nt-code, rgb(127 127 127 / 0.16));}.prose.svelte-xmynmn .code-block {position:relative;margin:0 0 10px;}.prose.svelte-xmynmn pre {margin:0;padding:10px 12px;overflow-x:auto;border-radius:var(--nt-card-radius, 10px);border:1px solid var(--nt-line, #2c2c31);background:var(--nt-card, #17171a);}.prose.svelte-xmynmn pre code {padding:0;background:none;font-size:12px;line-height:1.5;}.prose.svelte-xmynmn .copy-code {position:absolute;top:6px;right:6px;padding:2px 8px;border:1px solid var(--nt-line, #2c2c31);border-radius:6px;background:var(--nt-card, #17171a);color:var(--nt-faint, #8b8b94);font:inherit;font-size:11px;cursor:pointer;opacity:0;transition:opacity 0.15s ease;}.prose.svelte-xmynmn .code-block:hover .copy-code, .prose.svelte-xmynmn .copy-code:focus-visible {opacity:1;}.prose.svelte-xmynmn blockquote {margin:0 0 10px;padding-left:10px;border-left:2px solid var(--nt-line, #2c2c31);color:var(--nt-faint, #8b8b94);}.prose.svelte-xmynmn table {border-collapse:collapse;margin:0 0 10px;font-size:12px;display:block;overflow-x:auto;}.prose.svelte-xmynmn th, .prose.svelte-xmynmn td {padding:4px 8px;border:1px solid var(--nt-line, #2c2c31);text-align:left;}.prose.svelte-xmynmn th {font-weight:600;}.prose.svelte-xmynmn .cite {font-size:0.7em;padding:0 4px;margin-left:1px;border-radius:4px;background:var(--nt-code, rgb(127 127 127 / 0.16));color:var(--nt-faint, #8b8b94);}.status.svelte-xmynmn {font-size:12px;color:var(--nt-faint, #8b8b94);}.shimmer.svelte-xmynmn {background:linear-gradient(90deg, var(--nt-faint, #8b8b94) 0%, var(--nt-text, #ececef) 50%, var(--nt-faint, #8b8b94) 100%);background-size:200% 100%;-webkit-background-clip:text;background-clip:text;color:transparent;\n    animation: svelte-xmynmn-shimmer 1.8s linear infinite;}\n  @keyframes svelte-xmynmn-shimmer { from { background-position: 100% 0; } to { background-position: -100% 0; } }.dots.svelte-xmynmn {display:inline-flex;gap:4px;padding:6px 0;}.dots.svelte-xmynmn i:where(.svelte-xmynmn) {width:6px;height:6px;border-radius:50%;background:var(--nt-faint, #8b8b94); animation: svelte-xmynmn-blink 1.2s infinite ease-in-out;}.dots.svelte-xmynmn i:where(.svelte-xmynmn):nth-child(2) {animation-delay:0.15s;}.dots.svelte-xmynmn i:where(.svelte-xmynmn):nth-child(3) {animation-delay:0.3s;}\n  @keyframes svelte-xmynmn-blink { 0%, 80%, 100% { opacity: 0.25; } 40% { opacity: 1; } }.tasks.svelte-xmynmn {list-style:none;margin:0;padding:8px 10px;display:flex;flex-direction:column;gap:5px;border:1px solid var(--nt-line, #2c2c31);border-radius:var(--nt-card-radius, 10px);background:var(--nt-card, #17171a);font-size:12px;}.tasks.svelte-xmynmn li:where(.svelte-xmynmn) {display:flex;align-items:flex-start;gap:8px;}.tasks.svelte-xmynmn .mark:where(.svelte-xmynmn) {flex-shrink:0;display:grid;place-items:center;width:14px;height:14px;margin-top:2px;border:1.5px solid var(--nt-faint, #8b8b94);border-radius:50%;box-sizing:border-box;}.tasks.svelte-xmynmn .done:where(.svelte-xmynmn) .mark:where(.svelte-xmynmn) {border-color:var(--nt-accent, #8ab4ff);background:var(--nt-accent, #8ab4ff);}.tasks.svelte-xmynmn .done:where(.svelte-xmynmn) .mark:where(.svelte-xmynmn) svg:where(.svelte-xmynmn) {width:10px;height:10px;fill:none;stroke:var(--nt-on-accent, #0b0b0c);stroke-width:2.2;stroke-linecap:round;stroke-linejoin:round;}.tasks.svelte-xmynmn .done:where(.svelte-xmynmn), .tasks.svelte-xmynmn .cancelled:where(.svelte-xmynmn) {color:var(--nt-faint, #8b8b94);}.tasks.svelte-xmynmn .cancelled:where(.svelte-xmynmn) span:where(.svelte-xmynmn):last-child {text-decoration:line-through;}.tasks.svelte-xmynmn .active:where(.svelte-xmynmn) .mark:where(.svelte-xmynmn) {border-color:var(--nt-accent, #8ab4ff);}.tasks.svelte-xmynmn .spin:where(.svelte-xmynmn) {width:6px;height:6px;border-radius:50%;background:var(--nt-accent, #8ab4ff); animation: svelte-xmynmn-blink 1.2s infinite ease-in-out;}.sources.svelte-xmynmn {display:flex;flex-direction:column;gap:6px;}.sources-line.svelte-xmynmn {align-self:flex-start;display:inline-flex;align-items:center;gap:4px;margin:0 0 0 -6px;padding:3px 8px 3px 4px;border:0;border-radius:999px;background:transparent;color:var(--nt-faint, #8b8b94);font:inherit;font-size:12px;cursor:pointer;}.sources-line.svelte-xmynmn:hover {background:var(--nt-hover, rgb(127 127 127 / 0.12));color:var(--nt-text, #ececef);}.chev.svelte-xmynmn {width:12px;height:12px;fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round;transition:transform 0.15s ease;}.chev.open.svelte-xmynmn {transform:rotate(90deg);}.badge.svelte-xmynmn {display:grid;place-items:center;width:14px;height:14px;border-radius:50%;background:var(--nt-warn, #e0a23a);color:#000;font-size:10px;font-weight:700;}.source-list.svelte-xmynmn {list-style:none;margin:0;padding:8px 10px;display:flex;flex-direction:column;gap:6px;border:1px solid var(--nt-line, #2c2c31);border-radius:var(--nt-card-radius, 10px);background:var(--nt-card, #17171a);font-size:12px;}.source-list.svelte-xmynmn li:where(.svelte-xmynmn) {display:flex;align-items:baseline;gap:6px;min-width:0;flex-wrap:wrap;}.state.svelte-xmynmn {flex-shrink:0;width:6px;height:6px;border-radius:50%;background:var(--nt-ok, #3ecf8e);transform:translateY(-1px);}.s-empty.svelte-xmynmn .state:where(.svelte-xmynmn) {background:var(--nt-faint, #8b8b94);}.s-failed.svelte-xmynmn .state:where(.svelte-xmynmn) {background:var(--nt-error, #ff6b5e);}.s-running.svelte-xmynmn .state:where(.svelte-xmynmn) {background:var(--nt-accent, #8ab4ff); animation: svelte-xmynmn-blink 1.2s infinite ease-in-out;}.source-title.svelte-xmynmn {font-weight:500;}.source-detail.svelte-xmynmn {color:var(--nt-faint, #8b8b94);overflow-wrap:anywhere;}.s-failed.svelte-xmynmn .source-detail:where(.svelte-xmynmn) {color:var(--nt-error, #ff6b5e);}.reference.svelte-xmynmn .number:where(.svelte-xmynmn) {flex-shrink:0;min-width:16px;padding:0 4px;border-radius:4px;background:var(--nt-code, rgb(127 127 127 / 0.16));color:var(--nt-faint, #8b8b94);font-size:10px;text-align:center;}.reference.svelte-xmynmn a:where(.svelte-xmynmn) {color:var(--nt-accent, #8ab4ff);text-decoration:none;overflow-wrap:anywhere;}.reference.svelte-xmynmn a:where(.svelte-xmynmn):hover {text-decoration:underline;}.note.svelte-xmynmn {font-size:12px;color:var(--nt-faint, #8b8b94);}\n\n  /* What you can do with a message: quiet, and only on hover or focus, except under Nook's newest answer. */.actions.svelte-xmynmn, .meta.svelte-xmynmn {display:flex;align-items:center;gap:2px;color:var(--nt-faint, #8b8b94);font-size:11px;opacity:0;transition:opacity 0.15s ease;}.actions.svelte-xmynmn {flex-shrink:0;}.meta.svelte-xmynmn {margin:-2px 0 0 -6px;}.you-row.svelte-xmynmn:hover .actions:where(.svelte-xmynmn), .you-row.svelte-xmynmn:focus-within .actions:where(.svelte-xmynmn), .nook.svelte-xmynmn:hover .meta:where(.svelte-xmynmn), .nook.svelte-xmynmn:focus-within .meta:where(.svelte-xmynmn), .meta.last.svelte-xmynmn {opacity:1;}.time.svelte-xmynmn {padding:0 4px;font-variant-numeric:tabular-nums;white-space:nowrap;}.act.svelte-xmynmn {display:grid;place-items:center;width:24px;height:24px;padding:0;border:0;border-radius:6px;background:transparent;color:inherit;cursor:pointer;}.act.svelte-xmynmn:hover {background:var(--nt-hover, rgb(127 127 127 / 0.12));color:var(--nt-text, #ececef);}.act.svelte-xmynmn:focus-visible {outline:2px solid var(--nt-accent, #8ab4ff);outline-offset:1px;}.act.svelte-xmynmn svg:where(.svelte-xmynmn) {width:14px;height:14px;fill:none;stroke:currentColor;stroke-width:1.4;stroke-linecap:round;stroke-linejoin:round;}\n  @media (prefers-reduced-motion: reduce) {.shimmer.svelte-xmynmn, .dots.svelte-xmynmn i:where(.svelte-xmynmn), .spin.svelte-xmynmn, .s-running.svelte-xmynmn .state:where(.svelte-xmynmn) { animation: none;}.actions.svelte-xmynmn, .meta.svelte-xmynmn {transition:none;}.shimmer.svelte-xmynmn {color:var(--nt-faint, #8b8b94);background:none;}\n  }"
};
function Transcript($$anchor, $$props) {
	push($$props, true);
	append_styles$1($$anchor, $$css$1);
	/** Puts a question back in the composer; without it the action is left out. */
	/** How the surface writes a message's time ("14:05"); without it no time shows. */
	let copiedKey = /* @__PURE__ */ state(null);
	let copiedTimer;
	async function copyMessage(message, key) {
		await navigator.clipboard?.writeText(message.text).catch(() => {});
		set(copiedKey, key, true);
		clearTimeout(copiedTimer);
		copiedTimer = setTimeout(() => set(copiedKey, null), 1200);
	}
	const lastNook = /* @__PURE__ */ user_derived(() => {
		for (let index = $$props.messages.length - 1; index >= 0; index--) if ($$props.messages[index].fromNook) return index;
		return -1;
	});
	let opened = proxy({});
	const markdownTexts = /* @__PURE__ */ user_derived(() => ({
		copy: $$props.texts.copy,
		copyTitle: $$props.texts.copyTitle
	}));
	function keyOf(message, index) {
		return message.id || `${index}`;
	}
	function webHref(text) {
		try {
			const url = new URL(text || "");
			return url.protocol === "https:" || url.protocol === "http:" ? url.href : null;
		} catch {
			return null;
		}
	}
	async function click(e) {
		const target = e.target;
		const copy = target.closest("[data-copy-code]");
		if (copy) {
			const code = copy.parentElement?.querySelector("code")?.textContent ?? "";
			await navigator.clipboard?.writeText(code).catch(() => {});
			const before = copy.textContent;
			copy.textContent = $$props.texts.copied;
			setTimeout(() => copy.textContent = before, 1200);
			return;
		}
		const link = target.closest("a[href]");
		if (link) {
			e.preventDefault();
			const href = webHref(link.getAttribute("href"));
			if (href) window.open(href, "_blank", "noopener,noreferrer");
		}
	}
	var div = root_25();
	each(div, 23, () => $$props.messages, (message, index) => keyOf(message, index), ($$anchor, message, index$1) => {
		const key = /* @__PURE__ */ user_derived(() => keyOf(get(message), get(index$1)));
		const time = /* @__PURE__ */ user_derived(() => $$props.timeOf && get(message).at ? $$props.timeOf(get(message).at) : "");
		var fragment = comment();
		var node = first_child(fragment);
		var consequent_4 = ($$anchor) => {
			var div_1 = root_5();
			var div_2 = child(div_1);
			var node_1 = child(div_2);
			var consequent = ($$anchor) => {
				var span = root$1();
				var text_1 = only_child(span, true);
				template_effect(() => set_text(text_1, get(time)));
				append($$anchor, span);
			};
			if_block(node_1, ($$render) => {
				if (get(time)) $$render(consequent);
			});
			var node_2 = sibling(node_1, 2);
			var consequent_1 = ($$anchor) => {
				var button = root_1();
				template_effect(() => {
					set_attribute(button, "title", $$props.texts.reuse);
					set_attribute(button, "aria-label", $$props.texts.reuse);
				});
				delegated("click", button, () => $$props.onreuse(get(message).text));
				append($$anchor, button);
			};
			if_block(node_2, ($$render) => {
				if ($$props.onreuse && $$props.texts.reuse) $$render(consequent_1);
			});
			var node_3 = sibling(node_2, 2);
			var consequent_3 = ($$anchor) => {
				var button_1 = root_4();
				var node_4 = child(button_1);
				var consequent_2 = ($$anchor) => {
					append($$anchor, root_2());
				};
				var alternate = ($$anchor) => {
					append($$anchor, root_3());
				};
				if_block(node_4, ($$render) => {
					if (get(copiedKey) === get(key)) $$render(consequent_2);
					else $$render(alternate, -1);
				});
				reset(button_1);
				template_effect(() => {
					set_attribute(button_1, "title", get(copiedKey) === get(key) ? $$props.texts.copied : $$props.texts.copyMessage);
					set_attribute(button_1, "aria-label", get(copiedKey) === get(key) ? $$props.texts.copied : $$props.texts.copyMessage);
				});
				delegated("click", button_1, () => copyMessage(get(message), get(key)));
				append($$anchor, button_1);
			};
			if_block(node_3, ($$render) => {
				if ($$props.texts.copyMessage) $$render(consequent_3);
			});
			reset(div_2);
			var text_2 = only_child(sibling(div_2, 2), true);
			reset(div_1);
			template_effect(() => {
				set_attribute(div_1, "data-message", get(key));
				set_attribute(div_1, "data-index", get(index$1));
				set_text(text_2, get(message).text);
			});
			append($$anchor, div_1);
		};
		var alternate_3 = ($$anchor) => {
			var div_4 = root_24();
			let classes;
			var node_5 = child(div_4);
			var consequent_7 = ($$anchor) => {
				var ul = root_9();
				each(ul, 21, () => get(message).tasks, index, ($$anchor, task) => {
					var li = root_8();
					var span_1 = child(li);
					var node_6 = child(span_1);
					var consequent_5 = ($$anchor) => {
						append($$anchor, root_6());
					};
					var consequent_6 = ($$anchor) => {
						append($$anchor, root_7());
					};
					if_block(node_6, ($$render) => {
						if (get(task).status === "done") $$render(consequent_5);
						else if (get(task).status === "active") $$render(consequent_6, 1);
					});
					reset(span_1);
					var text_3 = only_child(sibling(span_1, 2), true);
					reset(li);
					template_effect(() => {
						set_class(li, 1, clsx(get(task).status), "svelte-xmynmn");
						set_text(text_3, get(task).text);
					});
					append($$anchor, li);
				});
				reset(ul);
				append($$anchor, ul);
			};
			if_block(node_5, ($$render) => {
				if (get(message).tasks?.length) $$render(consequent_7);
			});
			var node_7 = sibling(node_5, 2);
			var consequent_8 = ($$anchor) => {
				var div_5 = root_10();
				html(div_5, () => renderMarkdown(get(message).text, get(markdownTexts)), true);
				reset(div_5);
				append($$anchor, div_5);
			};
			var consequent_9 = ($$anchor) => {
				var span_4 = root_11();
				template_effect(() => set_attribute(span_4, "aria-label", $$props.texts.thinking));
				append($$anchor, span_4);
			};
			if_block(node_7, ($$render) => {
				if (get(message).text) $$render(consequent_8);
				else if (get(message).streaming && !get(message).status) $$render(consequent_9, 1);
			});
			var node_8 = sibling(node_7, 2);
			var consequent_10 = ($$anchor) => {
				var div_6 = root_12();
				var text_4 = only_child(div_6, true);
				template_effect(() => set_text(text_4, get(message).status));
				append($$anchor, div_6);
			};
			if_block(node_8, ($$render) => {
				if (get(message).streaming && get(message).status) $$render(consequent_10);
			});
			var node_9 = sibling(node_8, 2);
			var consequent_15 = ($$anchor) => {
				var div_7 = root_20();
				var button_2 = child(div_7);
				let classes_1;
				var svg_3 = child(button_2);
				let classes_2;
				var span_5 = sibling(svg_3, 2);
				let classes_3;
				var text_5 = only_child(span_5, true);
				var node_10 = sibling(span_5, 2);
				var consequent_11 = ($$anchor) => {
					append($$anchor, root_13());
				};
				var d = /* @__PURE__ */ user_derived(() => get(message).sources.items.some((s) => s.state === "failed"));
				if_block(node_10, ($$render) => {
					if (get(d)) $$render(consequent_11);
				});
				reset(button_2);
				var node_11 = sibling(button_2, 2);
				var consequent_14 = ($$anchor) => {
					var ul_1 = root_19();
					var node_12 = child(ul_1);
					each(node_12, 17, () => get(message).sources.items, index, ($$anchor, source) => {
						var li_1 = root_15();
						var span_7 = sibling(child(li_1), 2);
						var text_6 = only_child(span_7, true);
						var node_13 = sibling(span_7, 2);
						var consequent_12 = ($$anchor) => {
							var span_8 = root_14();
							var text_7 = only_child(span_8, true);
							template_effect(() => set_text(text_7, get(source).detail));
							append($$anchor, span_8);
						};
						if_block(node_13, ($$render) => {
							if (get(source).detail) $$render(consequent_12);
						});
						reset(li_1);
						template_effect(() => {
							set_class(li_1, 1, "s-" + get(source).state, "svelte-xmynmn");
							set_text(text_6, get(source).title);
						});
						append($$anchor, li_1);
					});
					each(sibling(node_12, 2), 17, () => get(message).sources.references ?? [], (reference) => reference.number, ($$anchor, reference) => {
						var li_2 = root_18();
						var span_9 = child(li_2);
						var text_8 = only_child(span_9, true);
						var node_15 = sibling(span_9, 2);
						var consequent_13 = ($$anchor) => {
							var a = root_16();
							var text_9 = only_child(a, true);
							template_effect(($0) => {
								set_attribute(a, "href", $0);
								set_text(text_9, get(reference).title);
							}, [() => webHref(get(reference).url)]);
							append($$anchor, a);
						};
						var d_1 = /* @__PURE__ */ user_derived(() => webHref(get(reference).url));
						var alternate_1 = ($$anchor) => {
							var span_10 = root_17();
							var text_10 = only_child(span_10, true);
							template_effect(() => set_text(text_10, get(reference).title));
							append($$anchor, span_10);
						};
						if_block(node_15, ($$render) => {
							if (get(d_1)) $$render(consequent_13);
							else $$render(alternate_1, -1);
						});
						reset(li_2);
						template_effect(() => set_text(text_8, get(reference).number));
						append($$anchor, li_2);
					});
					reset(ul_1);
					append($$anchor, ul_1);
				};
				if_block(node_11, ($$render) => {
					if (opened[get(key)]) $$render(consequent_14);
				});
				reset(div_7);
				template_effect(() => {
					classes_1 = set_class(button_2, 1, "sources-line svelte-xmynmn", null, classes_1, { running: get(message).sources.running });
					set_attribute(button_2, "aria-expanded", !!opened[get(key)]);
					classes_2 = set_class(svg_3, 0, "chev svelte-xmynmn", null, classes_2, { open: opened[get(key)] });
					classes_3 = set_class(span_5, 1, "svelte-xmynmn", null, classes_3, { shimmer: get(message).sources.running });
					set_text(text_5, get(message).sources.summary);
				});
				delegated("click", button_2, () => opened[get(key)] = !opened[get(key)]);
				append($$anchor, div_7);
			};
			if_block(node_9, ($$render) => {
				if (get(message).sources && (get(message).sources.items.length || get(message).sources.references?.length)) $$render(consequent_15);
			});
			var node_16 = sibling(node_9, 2);
			var consequent_16 = ($$anchor) => {
				var div_8 = root_21();
				var text_11 = only_child(div_8, true);
				template_effect(() => set_text(text_11, get(message).notice));
				append($$anchor, div_8);
			};
			if_block(node_16, ($$render) => {
				if (get(message).notice && !get(message).streaming) $$render(consequent_16);
			});
			var node_17 = sibling(node_16, 2);
			var consequent_17 = ($$anchor) => {
				var div_9 = root_22();
				var text_12 = only_child(div_9, true);
				template_effect(() => set_text(text_12, $$props.texts.onMac));
				append($$anchor, div_9);
			};
			if_block(node_17, ($$render) => {
				if (get(message).onMac) $$render(consequent_17);
			});
			var node_18 = sibling(node_17, 2);
			var consequent_21 = ($$anchor) => {
				var div_10 = root_23();
				let classes_4;
				var node_19 = child(div_10);
				var consequent_19 = ($$anchor) => {
					var button_3 = root_4();
					var node_20 = child(button_3);
					var consequent_18 = ($$anchor) => {
						append($$anchor, root_2());
					};
					var alternate_2 = ($$anchor) => {
						append($$anchor, root_3());
					};
					if_block(node_20, ($$render) => {
						if (get(copiedKey) === get(key)) $$render(consequent_18);
						else $$render(alternate_2, -1);
					});
					reset(button_3);
					template_effect(() => {
						set_attribute(button_3, "title", get(copiedKey) === get(key) ? $$props.texts.copied : $$props.texts.copyMessage);
						set_attribute(button_3, "aria-label", get(copiedKey) === get(key) ? $$props.texts.copied : $$props.texts.copyMessage);
					});
					delegated("click", button_3, () => copyMessage(get(message), get(key)));
					append($$anchor, button_3);
				};
				if_block(node_19, ($$render) => {
					if ($$props.texts.copyMessage) $$render(consequent_19);
				});
				var node_21 = sibling(node_19, 2);
				var consequent_20 = ($$anchor) => {
					var span_11 = root$1();
					var text_13 = only_child(span_11, true);
					template_effect(() => set_text(text_13, get(time)));
					append($$anchor, span_11);
				};
				if_block(node_21, ($$render) => {
					if (get(time)) $$render(consequent_20);
				});
				reset(div_10);
				template_effect(() => classes_4 = set_class(div_10, 1, "meta svelte-xmynmn", null, classes_4, { last: get(index$1) === get(lastNook) }));
				append($$anchor, div_10);
			};
			if_block(node_18, ($$render) => {
				if (!get(message).streaming && get(message).text && ($$props.texts.copyMessage || get(time))) $$render(consequent_21);
			});
			reset(div_4);
			template_effect(() => {
				classes = set_class(div_4, 1, "nook svelte-xmynmn", null, classes, { failed: get(message).failed });
				set_attribute(div_4, "data-message", get(key));
				set_attribute(div_4, "data-index", get(index$1));
			});
			append($$anchor, div_4);
		};
		if_block(node, ($$render) => {
			if (!get(message).fromNook) $$render(consequent_4);
			else $$render(alternate_3, -1);
		});
		append($$anchor, fragment);
	});
	reset(div);
	delegated("click", div, click);
	append($$anchor, div);
	pop();
}
delegate(["click"]);
// ../../apps/browser-extension/composer/PanelTranscript.svelte
var root = /* @__PURE__ */ from_html(`<div class="panel-transcript svelte-vng54z"><!></div>`);
var $$css = {
	hash: "svelte-vng54z",
	code: ".panel-transcript.svelte-vng54z {--nt-text: var(--text-strong);--nt-faint: var(--text-tertiary);--nt-line: var(--line2);--nt-card: var(--surface);--nt-card-radius: var(--radius-card);--nt-bubble: var(--bubble);--nt-bubble-radius: var(--radius-bubble);--nt-code: var(--graphite);--nt-hover: var(--row-hover);--nt-accent: var(--blue);--nt-on-accent: var(--canvas);--nt-ok: var(--mint);--nt-warn: var(--amber);--nt-error: var(--coral);--nt-mono: var(--mono);font:var(--body)/1.55 var(--sans);}"
};
function PanelTranscript($$anchor, $$props) {
	push($$props, true);
	append_styles$1($$anchor, $$css);
	const t = (key) => globalThis.chrome?.i18n?.getMessage(key) || key;
	const texts = {
		thinking: t("thinking"),
		onMac: t("onMacNote"),
		copy: t("copy"),
		copyTitle: t("copyCode"),
		copied: t("copied"),
		copyMessage: t("copyMessage"),
		reuse: t("askAgain")
	};
	var div = root();
	Transcript(child(div), {
		get messages() {
			return $$props.panel.messages;
		},
		get texts() {
			return texts;
		},
		get onreuse() {
			return $$props.onreuse;
		},
		get timeOf() {
			return $$props.timeOf;
		}
	});
	reset(div);
	append($$anchor, div);
	pop();
}
// ../../apps/browser-extension/composer/main.svelte.js
function questionsAsked(messages) {
	return askedBefore(messages.map((message) => ({
		fromUser: !message.fromNook,
		text: message.text || ""
	})));
}
/**
* Mounts the composer in `target`. `onsend(text, images)` gets the question and its pictures
* (`[{ mediaType, base64 }]`); `onstop` stops Nook's answer; `onbrain` asks for the newest models when the model menu
* opens; `onchoosebrain(id)` picks one.
*/
function mountComposer(target, { onsend, onstop, onbrain, onchoosebrain }) {
	const panel = proxy({
		connected: false,
		busy: false,
		canStop: false,
		history: [],
		conversation: null,
		brain: null
	});
	const component = mount(PanelComposer, {
		target,
		props: {
			panel,
			onsend,
			onstop,
			onbrain,
			onchoosebrain
		}
	});
	return {
		/** Changes what the composer shows: `connected`, `busy`, `canStop`, `history`, `conversation`, `brain`. */
		set(values) {
			Object.assign(panel, values);
		},
		focus() {
			component.focus();
		},
		fill(text) {
			component.fill(text);
		}
	};
}
/**
* Mounts the conversation in `target`; `set(messages)` draws it again. `onreuse(text)` puts a question back in the
* composer; `timeOf(at)` writes a message's time.
*/
function mountTranscript(target, { onreuse, timeOf } = {}) {
	const panel = proxy({ messages: [] });
	mount(PanelTranscript, {
		target,
		props: {
			panel,
			onreuse,
			timeOf
		}
	});
	return { set(messages) {
		panel.messages = messages;
	} };
}
export { mountComposer, mountTranscript, questionsAsked };
