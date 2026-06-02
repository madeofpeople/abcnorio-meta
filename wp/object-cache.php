<?php
/**
 * APCu object cache drop-in for WordPress.
 *
 * Uses APCu for persistent in-process caching across FrankenPHP worker requests.
 * Falls back silently to no-op if APCu is unavailable.
 *
 * Drop-in location: web/app/object-cache.php (Bedrock wp-content equivalent)
 * Revert: delete this file. WordPress will fall back to per-request memory cache.
 */

if (! function_exists('wp_cache_init')) {
    function wp_cache_init() {
        global $wp_object_cache;
        $wp_object_cache = new WP_Object_Cache_APCu();
    }
}

if (! function_exists('wp_cache_add')) {
    function wp_cache_add($key, $data, $group = '', $expire = 0) {
        global $wp_object_cache;
        return $wp_object_cache->add($key, $data, $group, $expire);
    }
}

if (! function_exists('wp_cache_set')) {
    function wp_cache_set($key, $data, $group = '', $expire = 0) {
        global $wp_object_cache;
        return $wp_object_cache->set($key, $data, $group, $expire);
    }
}

if (! function_exists('wp_cache_get')) {
    function wp_cache_get($key, $group = '', $force = false, &$found = null) {
        global $wp_object_cache;
        return $wp_object_cache->get($key, $group, $force, $found);
    }
}

if (! function_exists('wp_cache_delete')) {
    function wp_cache_delete($key, $group = '') {
        global $wp_object_cache;
        return $wp_object_cache->delete($key, $group);
    }
}

if (! function_exists('wp_cache_flush')) {
    function wp_cache_flush() {
        global $wp_object_cache;
        return $wp_object_cache->flush();
    }
}

if (! function_exists('wp_cache_flush_group')) {
    function wp_cache_flush_group($group) {
        global $wp_object_cache;
        return $wp_object_cache->flush_group($group);
    }
}

if (! function_exists('wp_cache_replace')) {
    function wp_cache_replace($key, $data, $group = '', $expire = 0) {
        global $wp_object_cache;
        return $wp_object_cache->replace($key, $data, $group, $expire);
    }
}

if (! function_exists('wp_cache_incr')) {
    function wp_cache_incr($key, $offset = 1, $group = '') {
        global $wp_object_cache;
        return $wp_object_cache->incr($key, $offset, $group);
    }
}

if (! function_exists('wp_cache_decr')) {
    function wp_cache_decr($key, $offset = 1, $group = '') {
        global $wp_object_cache;
        return $wp_object_cache->decr($key, $offset, $group);
    }
}

if (! function_exists('wp_cache_close')) {
    function wp_cache_close() { return true; }
}

if (! function_exists('wp_cache_add_global_groups')) {
    function wp_cache_add_global_groups($groups) {
        global $wp_object_cache;
        $wp_object_cache->add_global_groups($groups);
    }
}

if (! function_exists('wp_cache_add_non_persistent_groups')) {
    function wp_cache_add_non_persistent_groups($groups) {
        global $wp_object_cache;
        $wp_object_cache->add_non_persistent_groups($groups);
    }
}

if (! function_exists('wp_cache_switch_to_blog')) {
    function wp_cache_switch_to_blog($blog_id) {}
}

// ---------------------------------------------------------------------------

if (! class_exists('WP_Object_Cache_APCu')) :
class WP_Object_Cache_APCu {
    private string $site_prefix;
    private string $namespace_version;
    private array  $global_groups       = [];
    private array  $non_persistent_groups = [];
    private array  $local               = [];   // per-request store for non-persistent groups

    public function __construct() {
        // Prefix by site path to isolate caches across WP installs sharing the same APCu pool.
        $this->site_prefix = md5(ABSPATH) . ':';
        $this->namespace_version = $this->read_namespace_version();
        $this->synchronize_namespace();
    }

    private function key(string $key, string $group): string {
        $group = $group ?: 'default';
        return $this->site_prefix . $this->namespace_version . ':' . $group . ':' . $key;
    }

    private function read_namespace_version(): string {
        $path = ABSPATH . 'tmp/object-cache-namespace';

        if (! is_readable($path)) {
            return 'v1';
        }

        $value = trim((string) file_get_contents($path));

        if ($value === '') {
            return 'v1';
        }

        return substr(sha1($value), 0, 12);
    }

    private function can_inspect_cache(): bool {
        if (! function_exists('apcu_cache_info')) {
            return false;
        }

        if (PHP_SAPI === 'cli') {
            return (bool) ini_get('apc.enable_cli');
        }

        return true;
    }

    private function synchronize_namespace(): void {
        if (! $this->can_inspect_cache()) {
            return;
        }

        $marker_key = $this->site_prefix . '__namespace';
        $success = false;
        $previous = apcu_fetch($marker_key, $success);

        if ($success && $previous === $this->namespace_version) {
            return;
        }

        $info = apcu_cache_info(false);

        foreach ($info['cache_list'] ?? [] as $entry) {
            $entry_key = (string) ($entry['info'] ?? '');

            if (str_starts_with($entry_key, $this->site_prefix)) {
                apcu_delete($entry_key);
            }
        }

        apcu_store($marker_key, $this->namespace_version);
    }

    private function is_non_persistent(string $group): bool {
        return isset($this->non_persistent_groups[$group]);
    }

    public function add(string $key, mixed $data, string $group = '', int $expire = 0): bool {
        $group = $group ?: 'default';
        if ($this->is_non_persistent($group)) {
            if (isset($this->local[$group][$key])) return false;
            $this->local[$group][$key] = $data;
            return true;
        }
        $akey = $this->key($key, $group);
        if (apcu_exists($akey)) return false;
        return (bool) apcu_store($akey, $data, max(0, $expire));
    }

    public function set(string $key, mixed $data, string $group = '', int $expire = 0): bool {
        $group = $group ?: 'default';
        if ($this->is_non_persistent($group)) {
            $this->local[$group][$key] = $data;
            return true;
        }
        return (bool) apcu_store($this->key($key, $group), $data, max(0, $expire));
    }

    public function get(string $key, string $group = '', bool $force = false, ?bool &$found = null): mixed {
        $group = $group ?: 'default';
        if ($this->is_non_persistent($group)) {
            $found = isset($this->local[$group][$key]);
            return $found ? $this->local[$group][$key] : false;
        }
        $success = false;
        $value = apcu_fetch($this->key($key, $group), $success);
        $found = $success;
        return $success ? $value : false;
    }

    public function delete(string $key, string $group = ''): bool {
        $group = $group ?: 'default';
        if ($this->is_non_persistent($group)) {
            unset($this->local[$group][$key]);
            return true;
        }
        return apcu_delete($this->key($key, $group));
    }

    public function replace(string $key, mixed $data, string $group = '', int $expire = 0): bool {
        $group = $group ?: 'default';
        if ($this->is_non_persistent($group)) {
            if (! isset($this->local[$group][$key])) return false;
            $this->local[$group][$key] = $data;
            return true;
        }
        $akey = $this->key($key, $group);
        if (! apcu_exists($akey)) return false;
        return (bool) apcu_store($akey, $data, max(0, $expire));
    }

    public function incr(string $key, int $offset = 1, string $group = ''): int|false {
        $group = $group ?: 'default';
        if ($this->is_non_persistent($group)) return false;
        return apcu_inc($this->key($key, $group), $offset);
    }

    public function decr(string $key, int $offset = 1, string $group = ''): int|false {
        $group = $group ?: 'default';
        if ($this->is_non_persistent($group)) return false;
        return apcu_dec($this->key($key, $group), $offset);
    }

    public function flush(): bool {
        $this->local = [];
        if (! $this->can_inspect_cache()) {
            return true;
        }

        $info = apcu_cache_info(false);
        foreach ($info['cache_list'] ?? [] as $entry) {
            $entry_key = (string) ($entry['info'] ?? '');
            if (str_starts_with($entry_key, $this->site_prefix)) {
                apcu_delete($entry_key);
            }
        }
        return true;
    }

    public function flush_group(string $group): bool {
        unset($this->local[$group]);
        if (! $this->can_inspect_cache()) {
            return true;
        }

        $prefix = $this->site_prefix . $this->namespace_version . ':' . ($group ?: 'default') . ':';
        $info = apcu_cache_info(false);
        foreach ($info['cache_list'] ?? [] as $entry) {
            $entry_key = (string) ($entry['info'] ?? '');
            if (str_starts_with($entry_key, $prefix)) {
                apcu_delete($entry_key);
            }
        }
        return true;
    }

    public function add_global_groups(array|string $groups): void {
        foreach ((array) $groups as $g) {
            $this->global_groups[$g] = true;
        }
    }

    public function add_non_persistent_groups(array|string $groups): void {
        foreach ((array) $groups as $g) {
            $this->non_persistent_groups[$g] = true;
        }
    }
}
endif;
