<?php
/**
 * ALFa splash screen implementation (loaded by mu-plugins/alfa-splash-screen.php).
 */

if (!defined('ABSPATH')) {
    exit;
}

class Alfa_Splash_Screen {

    const VERSION = '1.0.0';
    const SESSION_KEY = 'alfa_qd_splash_dismissed';

    /** @var array<string, mixed>|null */
    private static $config_cache = null;

    public function __construct() {
        add_action('wp_enqueue_scripts', [$this, 'enqueue_assets']);
        add_action('wp_body_open', [$this, 'render_splash'], 1);
        add_filter('body_class', [$this, 'body_class']);
    }

    /** @return array<string, mixed> */
    private function config(): array {
        if (self::$config_cache !== null) {
            return self::$config_cache;
        }
        $path = __DIR__ . '/splash_config.json';
        if (!is_readable($path)) {
            self::$config_cache = [
                'splash_url'  => '',
                'splash_type' => 'none',
                'title'       => 'ALFa Quantum Dynamics',
                'subtitle'    => '',
            ];
            return self::$config_cache;
        }
        $decoded = json_decode((string) file_get_contents($path), true);
        self::$config_cache = is_array($decoded) ? $decoded : [];
        return self::$config_cache;
    }

    private function should_offer_splash(): bool {
        if (is_admin()) {
            return false;
        }
        return is_front_page() || is_home();
    }

    private function assets_base_url(): string {
        return content_url('mu-plugins/alfa-splash-screen');
    }

    private function media_url(string $relative): string {
        $cfg = $this->config();
        $rev = (int) ($cfg['splash_media_revision'] ?? 0);
        $url = trailingslashit($this->assets_base_url()) . ltrim($relative, '/');
        if ($rev > 0) {
            $url .= (str_contains($url, '?') ? '&' : '?') . 'smr=' . $rev;
        }
        return $url;
    }

    /** @param array<string, string> $classes */
    public function body_class(array $classes): array {
        if ($this->should_offer_splash()) {
            $classes[] = 'alfa-splash-pending';
        }
        return $classes;
    }

    public function enqueue_assets(): void {
        if (!$this->should_offer_splash()) {
            return;
        }
        $css = __DIR__ . '/alfa-splash-screen.css';
        $js = __DIR__ . '/alfa-splash-screen.js';
        if (file_exists($css)) {
            wp_enqueue_style(
                'alfa-splash-screen',
                content_url('mu-plugins/alfa-splash-screen/alfa-splash-screen.css'),
                [],
                self::VERSION
            );
        }
        if (file_exists($js)) {
            wp_enqueue_script(
                'alfa-splash-screen',
                content_url('mu-plugins/alfa-splash-screen/alfa-splash-screen.js'),
                [],
                self::VERSION,
                true
            );
            wp_localize_script('alfa-splash-screen', 'ALFA_SPLASH', [
                'sessionKey' => self::SESSION_KEY,
            ]);
        }
    }

    public function render_splash(): void {
        if (!$this->should_offer_splash()) {
            return;
        }

        $cfg = $this->config();
        $title = (string) ($cfg['title'] ?? 'ALFa Quantum Dynamics');
        $subtitle = (string) ($cfg['subtitle'] ?? '');
        $type = (string) ($cfg['splash_type'] ?? 'none');
        $rel = (string) ($cfg['splash_url'] ?? '');
        $video_url = ($type === 'video' && $rel !== '') ? $this->media_url($rel) : '';
        $flag_url = $this->media_url('assets/flags/us.svg');
        ?>
        <div id="alfa-splash-root" class="alfa-splash" hidden aria-hidden="true">
            <div class="alfa-splash__media" aria-hidden="true">
                <?php if ($video_url !== '') : ?>
                <video class="alfa-splash__video" autoplay loop muted playsinline>
                    <source src="<?php echo esc_url($video_url); ?>" type="video/mp4" />
                </video>
                <?php endif; ?>
                <div class="alfa-splash__scrim"></div>
            </div>
            <aside class="alfa-splash__veteran" aria-label="Veteran recognition">
                <img src="<?php echo esc_url($flag_url); ?>" alt="United States flag" width="90" height="47" decoding="async" />
                <p>Created by Disabled Veteran</p>
            </aside>
            <div class="alfa-splash__enter-wrap">
                <button type="button" id="alfa-splash-enter" class="alfa-splash__enter">Enter site</button>
            </div>
            <div class="alfa-splash__content">
                <h1 class="alfa-splash__title"><?php echo esc_html($title); ?></h1>
                <?php if ($subtitle !== '') : ?>
                <p class="alfa-splash__subtitle"><?php echo esc_html($subtitle); ?></p>
                <?php endif; ?>
            </div>
        </div>
        <?php
    }
}

new Alfa_Splash_Screen();
