<?php
/**
 * One-off: downscale all attachment originals and scaled working files to max 1600px on longest side.
 *
 * Run via:
 *   wp --allow-root --path=/app/web/wp eval-file /scripts/downscale-originals.php
 *
 * Safe to re-run — images already within the limit are skipped.
 * Modifies files in place; originals are not preserved after this script runs.
 */

define('MAX_SIDE', 1600);

$attachments = get_posts([
    'post_type'      => 'attachment',
    'post_mime_type' => 'image',
    'post_status'    => 'inherit',
    'numberposts'    => -1,
]);

$upload_dir = wp_upload_dir();
$base_dir   = trailingslashit($upload_dir['basedir']);

foreach ($attachments as $post) {
    $relative = get_post_meta($post->ID, '_wp_attached_file', true);
    if (!$relative) {
        WP_CLI::warning("ID {$post->ID}: no _wp_attached_file, skipping");
        continue;
    }

    $working_path = $base_dir . $relative;

    // WP stores the pre-scaled original filename in attachment metadata under 'original_image'
    $attachment_meta   = wp_get_attachment_metadata($post->ID);
    $original_filename = $attachment_meta['original_image'] ?? null;
    $original_path     = $original_filename ? dirname($working_path) . '/' . $original_filename : null;

    $paths = array_filter([$working_path, $original_path]);

    foreach ($paths as $path) {
        if (!file_exists($path)) {
            WP_CLI::log("ID {$post->ID}: missing file, skipping — {$path}");
            continue;
        }

        $editor = wp_get_image_editor($path);
        if (is_wp_error($editor)) {
            WP_CLI::warning("ID {$post->ID}: cannot open {$path} — " . $editor->get_error_message());
            continue;
        }

        $size   = $editor->get_size();
        $longest = max($size['width'], $size['height']);

        if ($longest <= MAX_SIDE) {
            WP_CLI::log("ID {$post->ID}: already within limit ({$size['width']}x{$size['height']}) — " . basename($path));
            continue;
        }

        $editor->resize(MAX_SIDE, MAX_SIDE, false);
        $result = $editor->save($path);

        if (is_wp_error($result)) {
            WP_CLI::warning("ID {$post->ID}: failed to save {$path} — " . $result->get_error_message());
            continue;
        }

        $new = $editor->get_size();
        WP_CLI::success("ID {$post->ID}: {$size['width']}x{$size['height']} → {$new['width']}x{$new['height']} — " . basename($path));
    }

    // Regenerate metadata so WP knows the new dimensions of the working file
    $updated_meta = wp_generate_attachment_metadata($post->ID, $working_path);
    wp_update_attachment_metadata($post->ID, $updated_meta);
    WP_CLI::log("ID {$post->ID}: metadata updated");
}

WP_CLI::success('Done.');
