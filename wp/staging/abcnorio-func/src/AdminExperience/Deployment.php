<?php

namespace abcnorio\CustomFunc\AdminExperience;

final class Deployment
{
    /**
     * @var array<string, bool>
     */
    private static array $saveTriggerQueuedTargets = [];

    /**
     * @return array<int, string>
     */
    private static function envKeys(): array
    {
        return ['dev', 'staging', 'production'];
    }

    private static function isValidEnv(string $env): bool
    {
        return in_array($env, self::envKeys(), true);
    }

    private static function orchestratorBaseUrl(): string
    {
        return rtrim(getenv('ASTRO_BUILD_TRIGGER_URL') ?: 'http://deploy-orchestrator:4011', '/');
    }

    private static function orchestratorSecret(): string
    {
        return (string) (getenv('ASTRO_BUILD_TRIGGER_SECRET') ?: '');
    }

    public static function registerHooks(): void
    {
        add_action('admin_menu', [self::class, 'addMenuPage']);
        add_action('admin_notices', [self::class, 'maybeRenderAdminNotice']);
        add_action('admin_enqueue_scripts', [self::class, 'enqueueAssets']);
        add_action('wp_ajax_abcnorio_trigger_build', [self::class, 'ajaxTriggerBuild']);
        add_action('wp_ajax_abcnorio_poll_build_status', [self::class, 'ajaxPollBuildStatus']);
        add_action('wp_ajax_abcnorio_download_backup', [self::class, 'ajaxDownloadBackup']);
        add_action('wp_ajax_abcnorio_restore_backup', [self::class, 'ajaxRestoreBackup']);
        add_action('save_post', [self::class, 'maybeQueueSaveTriggeredBuildForPost'], 20, 3);
        add_action('before_delete_post', [self::class, 'maybeQueueSaveTriggeredBuildForDelete'], 20, 1);
    }

    private static function saveTriggerEnabled(): bool
    {
        return (string) (getenv('WP_SAVE_TRIGGER_QUEUE_ENABLED') ?: '0') === '1';
    }

    private static function saveTriggerTarget(): string
    {
        $configured = sanitize_key((string) (getenv('WP_SAVE_TRIGGER_TARGET') ?: ''));
        if (in_array($configured, ['dev', 'staging'], true)) {
            return $configured;
        }

        $wpEnv = sanitize_key((string) (defined('WP_ENV') ? WP_ENV : ''));
        if (in_array($wpEnv, ['development', 'dev'], true)) {
            return 'dev';
        }

        if ($wpEnv === 'staging') {
            return 'staging';
        }

        return 'dev';
    }

    private static function shouldQueueForPost(
        int $postId,
        ?\WP_Post $post = null,
        bool $isUpdate = true
    ): bool {
        if (!self::saveTriggerEnabled()) {
            return false;
        }

        if (wp_is_post_revision($postId) || wp_is_post_autosave($postId)) {
            return false;
        }

        $resolvedPost = $post instanceof \WP_Post ? $post : get_post($postId);
        if (!$resolvedPost instanceof \WP_Post) {
            return false;
        }

        if ($resolvedPost->post_status === 'auto-draft') {
            return false;
        }

        if (in_array($resolvedPost->post_type, ['attachment', 'revision', 'nav_menu_item'], true)) {
            return false;
        }

        // Insert and update events can affect rendered frontend state.
        return true;
    }

    private static function queueSaveTriggeredBuild(string $reason = ''): void
    {
        $target = self::saveTriggerTarget();
        if ($target === '' || $target === 'production') {
            return;
        }

        if (isset(self::$saveTriggerQueuedTargets[$target])) {
            return;
        }

        self::$saveTriggerQueuedTargets[$target] = true;

        $triggerUrl = self::orchestratorBaseUrl();
        $secret = self::orchestratorSecret();

        $payload = [
            'target' => $target,
            'source' => 'save',
        ];

        if ($reason !== '') {
            $payload['reason'] = $reason;
        }

        $response = wp_remote_post("{$triggerUrl}/trigger", [
            'headers' => [
                'Content-Type' => 'application/json',
                'Authorization' => "Bearer {$secret}",
            ],
            'body' => wp_json_encode($payload),
            'timeout' => 5,
        ]);

        if (is_wp_error($response)) {
            error_log('[abcnorio][deploy] save-trigger enqueue failed: ' . $response->get_error_message());
            return;
        }

        $code = wp_remote_retrieve_response_code($response);
        if ($code < 200 || $code >= 300) {
            error_log('[abcnorio][deploy] save-trigger enqueue failed: HTTP ' . (string) $code);
        }
    }

    public static function maybeQueueSaveTriggeredBuildForPost(int $postId, \WP_Post $post, bool $update): void
    {
        if (!self::shouldQueueForPost($postId, $post, $update)) {
            return;
        }

        self::queueSaveTriggeredBuild('save_post');
    }

    public static function maybeQueueSaveTriggeredBuildForDelete(int $postId): void
    {
        if (!self::shouldQueueForPost($postId, null, true)) {
            return;
        }

        self::queueSaveTriggeredBuild('before_delete_post');
    }

    private static function backupArchiveDir(): string
    {
        $configured = trim((string) (getenv('ASTRO_BUILD_ARCHIVE_DIR') ?: ''));
        if ($configured !== '') {
            return rtrim($configured, '/');
        }

        $workspaceRoot = dirname(ABCNORIO_CUSTOM_FUNC_FILE, 4);
        return rtrim($workspaceRoot, '/') . '/astro/site/build-archives';
    }

    private static function deploymentStatusPath(): string
    {
        $configured = trim((string) (getenv('ASTRO_DEPLOYMENT_STATUS_FILE') ?: ''));
        if ($configured !== '') {
            return $configured;
        }

        return self::backupArchiveDir() . '/deployment-status.json';
    }

    private static function buildRootDir(string $env): string
    {
        $envKeyMap = [
            'dev' => 'DEV_BUILD_PATH',
            'staging' => 'STAGING_BUILD_PATH',
            'production' => 'PRODUCTION_BUILD_PATH',
        ];

        $envKey = $envKeyMap[$env] ?? null;
        if ($envKey !== null) {
            $configured = trim((string) (getenv($envKey) ?: ''));
            if ($configured !== '') {
                return rtrim($configured, '/');
            }
        }

        if ($env === 'production') {
            $configured = trim((string) (getenv('ASTRO_PRODUCTION_BUILD_DIR') ?: ''));
            if ($configured !== '') {
                return rtrim($configured, '/');
            }
        }

        $staticRoot = rtrim((string) (getenv('STATIC_SERVER_SITE_DIR') ?: ''), '/');
        if ($staticRoot === '') {
            return '';
        }

        $dirNameMap = [
            'dev' => 'dev',
            'staging' => 'staging',
            'production' => 'prod',
        ];

        $dirName = $dirNameMap[$env] ?? null;
        if ($dirName === null) {
            return '';
        }

        return $staticRoot . '/' . $dirName;
    }

    /**
     * @return array{ok: bool, message: string, names: array<int, string>}
     */
    private static function statusBackupNamesForEnv(string $env): array
    {
        $status = self::readDeploymentStatus();
        if (!$status['ok']) {
            return [
                'ok' => false,
                'message' => $status['message'],
                'names' => [],
            ];
        }

        $envStatus = $status['status']['envs'][$env] ?? null;
        if (!is_array($envStatus) || !isset($envStatus['backups']) || !is_array($envStatus['backups'])) {
            return [
                'ok' => false,
                'message' => __('Backup metadata is missing for selected environment.', 'abcnorio-func'),
                'names' => [],
            ];
        }

        $names = [];
        foreach ($envStatus['backups'] as $entry) {
            if (!is_array($entry)) {
                continue;
            }

            $name = trim((string) ($entry['name'] ?? ''));
            if ($name === '') {
                continue;
            }

            $names[] = $name;
        }

        return [
            'ok' => true,
            'message' => '',
            'names' => array_values(array_unique($names)),
        ];
    }

    /**
     * @param mixed $value
     */
    private static function normalizeBackupMtime($value): int
    {
        if (is_int($value)) {
            return $value;
        }

        if (is_string($value) && is_numeric($value)) {
            return (int) $value;
        }

        return 0;
    }

    /**
     * @param mixed $envStatus
     * @return array<int, array{name: string, mtime: int}>
     */
    private static function normalizeBackupsFromStatus($envStatus): array
    {
        if (!is_array($envStatus) || !isset($envStatus['backups']) || !is_array($envStatus['backups'])) {
            return [];
        }

        $out = [];
        foreach ($envStatus['backups'] as $entry) {
            if (!is_array($entry)) {
                continue;
            }

            $name = trim((string) ($entry['name'] ?? ''));
            if ($name === '') {
                continue;
            }

            $mtime = self::normalizeBackupMtime($entry['mtime'] ?? null);
            if ($mtime === 0 && isset($entry['createdAt']) && is_string($entry['createdAt'])) {
                $parsed = strtotime($entry['createdAt']);
                $mtime = is_int($parsed) ? $parsed : 0;
            }

            $out[] = [
                'name' => $name,
                'mtime' => $mtime,
            ];
        }

        usort($out, static function (array $a, array $b): int {
            return $b['mtime'] <=> $a['mtime'];
        });

        return array_slice($out, 0, 3);
    }

    /**
     * @param mixed $decoded
     * @return array{ok: bool, message: string, status: array<string, mixed>}
     */
    private static function validateDeploymentStatus($decoded): array
    {
        if (!is_array($decoded) || !isset($decoded['envs']) || !is_array($decoded['envs'])) {
            return [
                'ok' => false,
                'message' => __('Status file schema is invalid: missing envs object.', 'abcnorio-func'),
                'status' => [],
            ];
        }

        foreach (self::envKeys() as $env) {
            $envStatus = $decoded['envs'][$env] ?? null;
            if (!is_array($envStatus)) {
                return [
                    'ok' => false,
                    'message' => sprintf(
                        /* translators: %s: Environment key. */
                        __('Status file schema is invalid: missing %s env entry.', 'abcnorio-func'),
                        $env
                    ),
                    'status' => [],
                ];
            }

            $currentBuild = $envStatus['currentBuild'] ?? null;
            if (!is_array($currentBuild) || !array_key_exists('hasBuild', $currentBuild) || !is_bool($currentBuild['hasBuild'])) {
                return [
                    'ok' => false,
                    'message' => sprintf(
                        /* translators: %s: Environment key. */
                        __('Status file schema is invalid: %s currentBuild.hasBuild must be boolean.', 'abcnorio-func'),
                        $env
                    ),
                    'status' => [],
                ];
            }

            if (!isset($envStatus['backups']) || !is_array($envStatus['backups'])) {
                return [
                    'ok' => false,
                    'message' => sprintf(
                        /* translators: %s: Environment key. */
                        __('Status file schema is invalid: %s backups must be array.', 'abcnorio-func'),
                        $env
                    ),
                    'status' => [],
                ];
            }
        }

        return [
            'ok' => true,
            'message' => '',
            'status' => $decoded,
        ];
    }

    /**
     * @return array{ok: bool, message: string, status: array<string, mixed>}
     */
    private static function readDeploymentStatus(): array
    {
        $path = self::deploymentStatusPath();

        if (!is_file($path)) {
            return [
                'ok' => false,
                'message' => sprintf(
                    /* translators: %s: Status file path. */
                    __('Deployment status file not found: %s', 'abcnorio-func'),
                    $path
                ),
                'status' => [],
            ];
        }

        if (!is_readable($path)) {
            return [
                'ok' => false,
                'message' => sprintf(
                    /* translators: %s: Status file path. */
                    __('Deployment status file is not readable: %s', 'abcnorio-func'),
                    $path
                ),
                'status' => [],
            ];
        }

        $raw = file_get_contents($path);
        if (!is_string($raw) || trim($raw) === '') {
            return [
                'ok' => false,
                'message' => __('Deployment status file is empty.', 'abcnorio-func'),
                'status' => [],
            ];
        }

        $decoded = json_decode($raw, true);
        if (!is_array($decoded)) {
            return [
                'ok' => false,
                'message' => __('Deployment status file contains invalid JSON.', 'abcnorio-func'),
                'status' => [],
            ];
        }

        return self::validateDeploymentStatus($decoded);
    }

    private static function resolveBackupFile(string $requested, string $env): string
    {
        if ($requested === '') {
            wp_die(__('Missing backup file.', 'abcnorio-func'), 400);
        }

        $statusBackups = self::statusBackupNamesForEnv($env);
        if (!$statusBackups['ok']) {
            wp_die(__('Backup list unavailable from deployment status. Check status file health and retry.', 'abcnorio-func'), 503);
        }

        if (!in_array($requested, $statusBackups['names'], true)) {
            wp_die(__('Backup file not found.', 'abcnorio-func'), 404);
        }

        $archiveDir = self::backupArchiveDir();
        $archiveRealDir = realpath($archiveDir);
        if ($archiveRealDir === false) {
            wp_die(__('Backup directory not found.', 'abcnorio-func'), 404);
        }

        $candidatePath = $archiveRealDir . '/' . $requested;
        $realFile = realpath($candidatePath);
        if ($realFile === false || strpos($realFile, $archiveRealDir . '/') !== 0 || !is_file($realFile)) {
            wp_die(__('Backup file not found.', 'abcnorio-func'), 404);
        }

        return $realFile;
    }

    private static function rrmdirContents(string $dir): void
    {
        $entries = scandir($dir);
        if (!is_array($entries)) {
            return;
        }

        foreach ($entries as $entry) {
            if ($entry === '.' || $entry === '..') {
                continue;
            }

            $path = $dir . '/' . $entry;
            if (is_dir($path) && !is_link($path)) {
                self::rrmdirContents($path);
                @rmdir($path);
                continue;
            }

            @unlink($path);
        }
    }

    private static function copyDirRecursive(string $source, string $destination): bool
    {
        if (!is_dir($source) || !is_dir($destination)) {
            return false;
        }

        $iterator = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($source, \FilesystemIterator::SKIP_DOTS),
            \RecursiveIteratorIterator::SELF_FIRST
        );

        foreach ($iterator as $item) {
            $subPath = ltrim(substr((string) $item->getPathname(), strlen($source)), '/');
            $destPath = $destination . '/' . $subPath;

            if ($item->isDir()) {
                if (!is_dir($destPath) && !mkdir($destPath, 0775, true) && !is_dir($destPath)) {
                    return false;
                }
                continue;
            }

            $parent = dirname($destPath);
            if (!is_dir($parent) && !mkdir($parent, 0775, true) && !is_dir($parent)) {
                return false;
            }

            if (!copy((string) $item->getPathname(), $destPath)) {
                return false;
            }
        }

        return true;
    }

    private static function resolveExtractedRestoreSource(string $tempDir, string $targetDir): string
    {
        $expectedDirName = basename($targetDir);
        $expectedPath = $tempDir . '/' . $expectedDirName;
        if (is_dir($expectedPath)) {
            return $expectedPath;
        }

        $entries = scandir($tempDir);
        if (!is_array($entries)) {
            return '';
        }

        $topLevelDirs = [];
        $hasTopLevelFiles = false;

        foreach ($entries as $entry) {
            if ($entry === '.' || $entry === '..') {
                continue;
            }

            $path = $tempDir . '/' . $entry;
            if (is_dir($path) && !is_link($path)) {
                $topLevelDirs[] = $path;
                continue;
            }

            if (is_file($path)) {
                $hasTopLevelFiles = true;
            }
        }

        // Archive already contains production files at root.
        if ($hasTopLevelFiles) {
            return $tempDir;
        }

        // Common archive shape: exactly one top-level folder.
        if (count($topLevelDirs) === 1) {
            return $topLevelDirs[0];
        }

        // Fallback for older archives with nested paths.
        $matches = [];
        $iterator = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($tempDir, \FilesystemIterator::SKIP_DOTS),
            \RecursiveIteratorIterator::SELF_FIRST
        );

        foreach ($iterator as $item) {
            if (!$item->isDir()) {
                continue;
            }

            if ($item->getBasename() === $expectedDirName) {
                $matches[] = (string) $item->getPathname();
            }
        }

        return count($matches) === 1 ? $matches[0] : '';
    }

    public static function addMenuPage(): void
    {
        add_menu_page(
            __('Deployment', 'abcnorio-func'),
            __('Deployment', 'abcnorio-func'),
            'manage_options',
            'abcnorio-deployment',
            [self::class, 'renderPage'],
            'dashicons-controls-repeat',
            3
        );
    }

    public static function maybeRenderAdminNotice(): void
    {
        $page = sanitize_key((string) ($_GET['page'] ?? ''));
        if ($page !== 'abcnorio-deployment') {
            return;
        }

        $noticeType = sanitize_key((string) ($_GET['deployment_notice'] ?? ''));
        $noticeEnv = sanitize_key((string) ($_GET['deployment_env'] ?? ''));
        $noticeMessage = sanitize_text_field((string) ($_GET['deployment_message'] ?? ''));

        if ($noticeType !== '' && $noticeMessage !== '') {
            $class = $noticeType === 'error' ? 'notice notice-error is-dismissible' : 'notice notice-success is-dismissible';
            printf(
                '<div class="%1$s"><p>%2$s</p></div>',
                esc_attr($class),
                esc_html($noticeMessage)
            );
        }

        $restored = sanitize_file_name((string) ($_GET['restored'] ?? ''));
        if ($restored !== '') {
            printf(
                '<div class="notice notice-success is-dismissible"><p>%s</p></div>',
                esc_html(sprintf(__('Restore completed: %s', 'abcnorio-func'), $restored))
            );
        }

        $deployed = sanitize_key((string) ($_GET['deployed'] ?? ''));
        if ($deployed !== '') {
            $message = $deployed === 'production'
                ? __('Backup and deployment complete.', 'abcnorio-func')
                : sprintf(
                    /* translators: %s: Environment label. */
                    __('Deployment complete for %s.', 'abcnorio-func'),
                    ucfirst($deployed)
                );

            printf(
                '<div class="notice notice-success is-dismissible"><p>%s</p></div>',
                esc_html($message)
            );
        }
    }

    /**
     * @return array{statusOk: bool, statusMessage: string, targets: array<string, array{previewUrl: string, hasBuild: bool, backups: array<int, array{name: string, mtime: int}>}>}
     */
    private static function deploymentTargets(): array
    {
        $status = self::readDeploymentStatus();
        $targets = [];

        foreach (self::envKeys() as $env) {
            $previewEnvMap = [
                'dev' => 'DEV_FRONTEND_URL',
                'staging' => 'STAGING_FRONTEND_URL',
                'production' => 'PRODUCTION_FRONTEND_URL',
            ];

            $envStatus = $status['ok'] ? ($status['status']['envs'][$env] ?? []) : [];
            $currentBuild = is_array($envStatus) ? ($envStatus['currentBuild'] ?? []) : [];
            $hasBuild = is_array($currentBuild) && isset($currentBuild['hasBuild']) && is_bool($currentBuild['hasBuild'])
                ? $currentBuild['hasBuild']
                : false;

            $targets[$env] = [
                'previewUrl' => (string) (getenv($previewEnvMap[$env]) ?: ''),
                'hasBuild' => $hasBuild,
                'backups' => self::normalizeBackupsFromStatus($envStatus),
            ];
        }

        return [
            'statusOk' => $status['ok'],
            'statusMessage' => $status['message'],
            'targets' => $targets,
        ];
    }

    public static function enqueueAssets(string $hook): void
    {
        if ($hook !== 'toplevel_page_abcnorio-deployment') {
            return;
        }

        $view = self::deploymentTargets();
        $jsUrl = plugins_url('resources/js/deployment.js', ABCNORIO_CUSTOM_FUNC_FILE);
        wp_enqueue_script('abcnorio-deployment', $jsUrl, [], '1.0.0', true);
        wp_localize_script('abcnorio-deployment', 'abcnorioDeployment', [
            'ajaxUrl'      => admin_url('admin-ajax.php'),
            'triggerNonce' => wp_create_nonce('abcnorio_trigger_build'),
            'pollNonce'    => wp_create_nonce('abcnorio_poll_build_status'),
            'targets' => $view['targets'],
            'statusOk' => $view['statusOk'],
        ]);
    }

    public static function renderPage(): void
    {
        $activeTab = sanitize_key((string) ($_GET['tab'] ?? 'dev'));
        if (!self::isValidEnv($activeTab)) {
            $activeTab = 'dev';
        }

        $view = self::deploymentTargets();
        $targets = $view['targets'];
        $statusOk = $view['statusOk'];
        $statusMessage = $view['statusMessage'];
        $backupDownloadNonce = wp_create_nonce('abcnorio_download_backup');
        $backupRestoreNonce = wp_create_nonce('abcnorio_restore_backup');
        ?>
        <div class="wrap">
            <h1><?php esc_html_e('Deployment', 'abcnorio-func'); ?></h1>

            <?php if (!$statusOk) : ?>
                <div class="notice notice-error" style="margin: 1rem 0;">
                    <p><strong><?php esc_html_e('Deployment actions are currently blocked.', 'abcnorio-func'); ?></strong></p>
                    <p><?php echo esc_html($statusMessage); ?></p>
                    <p style="margin-bottom: 0;">
                        <?php esc_html_e('Troubleshooting: verify orchestrator is running, run one successful deploy to regenerate status, then refresh this page.', 'abcnorio-func'); ?>
                    </p>
                </div>
            <?php endif; ?>

            <nav class="nav-tab-wrapper" id="deployment-tabs">
                <a href="#tab-dev" class="nav-tab<?php echo $activeTab === 'dev' ? ' nav-tab-active' : ''; ?>" data-tab="dev">
                    <?php esc_html_e('Dev', 'abcnorio-func'); ?>
                </a>
                <a href="#tab-staging" class="nav-tab<?php echo $activeTab === 'staging' ? ' nav-tab-active' : ''; ?>" data-tab="staging">
                    <?php esc_html_e('Staging', 'abcnorio-func'); ?>
                </a>
                <a href="#tab-production" class="nav-tab<?php echo $activeTab === 'production' ? ' nav-tab-active' : ''; ?>" data-tab="production">
                    <?php esc_html_e('Production', 'abcnorio-func'); ?>
                </a>
            </nav>

            <?php foreach (['dev', 'staging'] as $env) : ?>
            <div
                id="tab-<?php echo esc_attr($env); ?>"
                class="deployment-tab<?php echo $activeTab !== $env ? ' hidden' : ''; ?>"
            >
                <div style="margin-top: 1.5rem; display: flex; gap: 1rem; align-items: center; flex-wrap: wrap;">
                    <button
                        class="button button-primary js-trigger-build"
                        data-target="<?php echo esc_attr($env); ?>"
                        data-label="<?php esc_attr_e('Run Static Build', 'abcnorio-func'); ?>"
                        <?php disabled(!$statusOk); ?>
                    >
                        <?php esc_html_e('Run Static Build', 'abcnorio-func'); ?>
                    </button>
                    <a
                        href="<?php echo esc_url($targets[$env]['previewUrl'] ?: '#'); ?>"
                        class="button js-preview-link<?php echo (empty($targets[$env]['previewUrl']) || !$targets[$env]['hasBuild']) ? ' hidden' : ''; ?>"
                        data-env="<?php echo esc_attr($env); ?>"
                        target="_blank"
                        rel="noopener"
                    >
                        <?php esc_html_e('Preview', 'abcnorio-func'); ?>
                    </a>
                    <?php if ($env === 'dev') : ?>
                    <a
                        href="<?php echo esc_url($targets['dev']['previewUrl'] ?: '#'); ?>"
                        class="button js-live-preview-link<?php echo empty($targets['dev']['previewUrl']) ? ' hidden' : ''; ?>"
                        target="_blank"
                        rel="noopener"
                    >
                        <?php esc_html_e('Development Preview', 'abcnorio-func'); ?>
                    </a>
                    <?php endif; ?>
                    <span class="js-build-status" style="color: #666;"></span>
                </div>

                <div style="margin-top: 1rem;">
                    <strong>
                        <?php
                        printf(
                            /* translators: %s: Environment label. */
                            esc_html__('%s Backups', 'abcnorio-func'),
                            esc_html(ucfirst($env))
                        );
                        ?>
                    </strong>
                    <?php if ($targets[$env]['backups'] === []) : ?>
                        <p style="margin: 0.5rem 0 0; color: #666;">
                            <?php esc_html_e('No backup archives found yet.', 'abcnorio-func'); ?>
                        </p>
                    <?php else : ?>
                        <ul style="margin: 0.5rem 0 0 1.25rem;">
                            <?php foreach ($targets[$env]['backups'] as $backup) : ?>
                                <li>
                                    <span><?php echo esc_html($backup['name']); ?></span>
                                    <span style="margin-left: 0.5rem; display: inline-flex; gap: 0.5rem;">
                                    <a
                                        href="<?php echo esc_url(add_query_arg([
                                            'action' => 'abcnorio_download_backup',
                                            'env' => rawurlencode($env),
                                            'nonce' => $backupDownloadNonce,
                                            'file' => rawurlencode($backup['name']),
                                        ], admin_url('admin-ajax.php'))); ?>"
                                        class="button button-secondary button-small"
                                    >
                                        <?php esc_html_e('Download', 'abcnorio-func'); ?>
                                    </a>
                                    <a
                                        href="<?php echo esc_url(add_query_arg([
                                            'action' => 'abcnorio_restore_backup',
                                            'env' => rawurlencode($env),
                                            'nonce' => $backupRestoreNonce,
                                            'file' => rawurlencode($backup['name']),
                                        ], admin_url('admin-ajax.php'))); ?>"
                                        class="button button-small<?php echo !$statusOk ? ' disabled' : ''; ?>"
                                        <?php if (!$statusOk) : ?>aria-disabled="true" onclick="return false;"<?php else : ?>
                                        onclick="return confirm('<?php echo esc_js(sprintf(__('Restore this backup to %s? This replaces current files for that environment.', 'abcnorio-func'), ucfirst($env))); ?>');"
                                        <?php endif; ?>
                                    >
                                        <?php esc_html_e('Restore', 'abcnorio-func'); ?>
                                    </a>
                                    </span>
                                </li>
                            <?php endforeach; ?>
                        </ul>
                    <?php endif; ?>
                </div>
            </div>
            <?php endforeach; ?>

            <div id="tab-production" class="deployment-tab<?php echo $activeTab !== 'production' ? ' hidden' : ''; ?>">
                <div style="margin-top: 1.5rem;">
                    <p style="color: #666; margin-bottom: 1rem;">
                        <?php esc_html_e('Backs up the current production build, then deploys the latest build to production.', 'abcnorio-func'); ?>
                    </p>
                    <div style="display: flex; gap: 1rem; align-items: center; flex-wrap: wrap;">
                        <button
                            class="button button-primary js-trigger-build"
                            data-target="production"
                            data-label="<?php esc_attr_e('Deploy to Production', 'abcnorio-func'); ?>"
                            data-confirm="<?php esc_attr_e('Deploy to production? This will replace the live site. Continue?', 'abcnorio-func'); ?>"
                            <?php disabled(!$statusOk); ?>
                        >
                            <?php esc_html_e('Deploy to Production', 'abcnorio-func'); ?>
                        </button>
                        <span class="js-build-status" style="color: #666;"></span>
                        <a
                            href="<?php echo esc_url($targets['production']['previewUrl'] ?: '#'); ?>"
                            class="button js-preview-link<?php echo (empty($targets['production']['previewUrl']) || !$targets['production']['hasBuild']) ? ' hidden' : ''; ?>"
                            data-env="production"
                            target="_blank"
                            rel="noopener"
                        >
                            <?php esc_html_e('View Site', 'abcnorio-func'); ?>
                        </a>
                    </div>

                    <div style="margin-top: 1rem;">
                        <strong><?php esc_html_e('Recent Production Backups', 'abcnorio-func'); ?></strong>
                        <?php if ($targets['production']['backups'] === []) : ?>
                            <p style="margin: 0.5rem 0 0; color: #666;">
                                <?php esc_html_e('No backup archives found yet.', 'abcnorio-func'); ?>
                            </p>
                        <?php else : ?>
                            <ul style="margin: 0.5rem 0 0 1.25rem;">
                                <?php foreach ($targets['production']['backups'] as $backup) : ?>
                                    <li>
                                        <span><?php echo esc_html($backup['name']); ?></span>
                                        <span style="margin-left: 0.5rem; display: inline-flex; gap: 0.5rem;">
                                        <a
                                            href="<?php echo esc_url(add_query_arg([
                                                'action' => 'abcnorio_download_backup',
                                                'env' => 'production',
                                                'nonce' => $backupDownloadNonce,
                                                'file' => rawurlencode($backup['name']),
                                            ], admin_url('admin-ajax.php'))); ?>"
                                            class="button button-secondary button-small"
                                        >
                                            <?php esc_html_e('Download', 'abcnorio-func'); ?>
                                        </a>
                                        <a
                                            href="<?php echo esc_url(add_query_arg([
                                                'action' => 'abcnorio_restore_backup',
                                                'env' => 'production',
                                                'nonce' => $backupRestoreNonce,
                                                'file' => rawurlencode($backup['name']),
                                            ], admin_url('admin-ajax.php'))); ?>"
                                                class="button button-small<?php echo !$statusOk ? ' disabled' : ''; ?>"
                                                <?php if (!$statusOk) : ?>aria-disabled="true" onclick="return false;"<?php else : ?>
                                                onclick="return confirm('<?php echo esc_js(__('Restore this backup to production? This replaces current production files.', 'abcnorio-func')); ?>');"
                                                <?php endif; ?>
                                        >
                                            <?php esc_html_e('Restore', 'abcnorio-func'); ?>
                                        </a>
                                        </span>
                                    </li>
                                <?php endforeach; ?>
                            </ul>
                        <?php endif; ?>
                    </div>
                </div>
            </div>
        </div>
        <?php
    }

    public static function ajaxTriggerBuild(): void
    {
        check_ajax_referer('abcnorio_trigger_build', 'nonce');

        if (!current_user_can('manage_options')) {
            wp_send_json_error(['message' => 'Insufficient permissions'], 403);
        }

        $target = sanitize_key($_POST['target'] ?? '');
        if (!self::isValidEnv($target)) {
            wp_send_json_error(['message' => 'Invalid target'], 400);
        }

        $triggerUrl = self::orchestratorBaseUrl();
        $secret     = self::orchestratorSecret();

        $response = wp_remote_post("{$triggerUrl}/trigger", [
            'headers' => [
                'Content-Type'  => 'application/json',
                'Authorization' => "Bearer {$secret}",
            ],
            'body'    => wp_json_encode(['target' => $target]),
            'timeout' => 10,
        ]);

        if (is_wp_error($response)) {
            wp_send_json_error(['message' => $response->get_error_message()], 502);
        }

        $code = wp_remote_retrieve_response_code($response);
        $body = json_decode(wp_remote_retrieve_body($response), true);

        if ($code === 409) {
            wp_send_json_error(['message' => 'A build is already running'], 409);
        }

        if ($code !== 202) {
            wp_send_json_error(['message' => 'Trigger failed', 'detail' => $body], $code);
        }

        wp_send_json_success($body);
    }

    public static function ajaxPollBuildStatus(): void
    {
        check_ajax_referer('abcnorio_poll_build_status', 'nonce');

        if (!current_user_can('manage_options')) {
            wp_send_json_error(['message' => 'Insufficient permissions'], 403);
        }

        $triggerUrl = self::orchestratorBaseUrl();
        $secret     = self::orchestratorSecret();

        $response = wp_remote_get("{$triggerUrl}/status", [
            'headers' => ['Authorization' => "Bearer {$secret}"],
            'timeout' => 5,
        ]);

        if (is_wp_error($response)) {
            wp_send_json_error(['message' => $response->get_error_message()], 502);
        }

        $body = json_decode(wp_remote_retrieve_body($response), true);
        wp_send_json_success($body);
    }

    public static function ajaxDownloadBackup(): void
    {
        $nonce = sanitize_text_field((string) ($_GET['nonce'] ?? ''));
        if (!wp_verify_nonce($nonce, 'abcnorio_download_backup')) {
            wp_die(__('Invalid request.', 'abcnorio-func'), 403);
        }

        if (!current_user_can('manage_options')) {
            wp_die(__('Insufficient permissions.', 'abcnorio-func'), 403);
        }

        $env = sanitize_key((string) ($_GET['env'] ?? ''));
        if (!self::isValidEnv($env)) {
            wp_die(__('Invalid backup environment.', 'abcnorio-func'), 400);
        }

        $requested = sanitize_file_name((string) ($_GET['file'] ?? ''));
        $realFile = self::resolveBackupFile($requested, $env);

        nocache_headers();
        header('Content-Description: File Transfer');
        header('Content-Type: application/zip');
        header('Content-Disposition: attachment; filename="' . basename($realFile) . '"');
        header('Content-Length: ' . (string) filesize($realFile));
        readfile($realFile);
        exit;
    }

    public static function ajaxRestoreBackup(): void
    {
        $nonce = sanitize_text_field((string) ($_GET['nonce'] ?? ''));
        if (!wp_verify_nonce($nonce, 'abcnorio_restore_backup')) {
            wp_die(__('Invalid request.', 'abcnorio-func'), 403);
        }

        if (!current_user_can('manage_options')) {
            wp_die(__('Insufficient permissions.', 'abcnorio-func'), 403);
        }

        $env = sanitize_key((string) ($_GET['env'] ?? ''));
        if (!self::isValidEnv($env)) {
            wp_die(__('Invalid backup environment.', 'abcnorio-func'), 400);
        }

        $requested = sanitize_file_name((string) ($_GET['file'] ?? ''));
        $realFile = self::resolveBackupFile($requested, $env);

        $targetDir = self::buildRootDir($env);
        if ($targetDir === '' || !is_dir($targetDir)) {
            wp_die(__('Build directory not found for requested environment.', 'abcnorio-func'), 500);
        }

        if (!class_exists('\ZipArchive')) {
            wp_die(__('Zip extension is not available.', 'abcnorio-func'), 500);
        }

        $zip = new \ZipArchive();
        if ($zip->open($realFile) !== true) {
            wp_die(__('Could not open backup archive.', 'abcnorio-func'), 500);
        }

        $tempRoot = rtrim((string) sys_get_temp_dir(), '/');
        $tempDir = $tempRoot . '/abcnorio-restore-' . wp_generate_password(12, false, false);
        if (!mkdir($tempDir, 0775, true) && !is_dir($tempDir)) {
            $zip->close();
            wp_die(__('Could not prepare restore workspace.', 'abcnorio-func'), 500);
        }

        $extractOk = $zip->extractTo($tempDir);
        $zip->close();
        if (!$extractOk) {
            self::rrmdirContents($tempDir);
            @rmdir($tempDir);
            wp_die(__('Could not extract backup archive.', 'abcnorio-func'), 500);
        }

        $extractedSource = self::resolveExtractedRestoreSource($tempDir, $targetDir);
        if ($extractedSource === '') {
            self::rrmdirContents($tempDir);
            @rmdir($tempDir);
            wp_die(__('Archive structure is invalid for restore.', 'abcnorio-func'), 500);
        }

        self::rrmdirContents($targetDir);
        if (!self::copyDirRecursive($extractedSource, $targetDir)) {
            self::rrmdirContents($tempDir);
            @rmdir($tempDir);
            wp_die(__('Restore failed while copying files.', 'abcnorio-func'), 500);
        }

        self::rrmdirContents($tempDir);
        @rmdir($tempDir);

        $redirect = add_query_arg(
            [
                'page' => 'abcnorio-deployment',
                'tab' => $env,
                'restored' => rawurlencode($requested),
            ],
            admin_url('admin.php')
        );
        wp_safe_redirect($redirect);
        exit;
    }
}
