<?php
/**
 * Plugin Name: ALFa Site Chrome
 * Description: Unified top nav, homepage-matching layout on inner pages, minimal footer.
 * Version:     1.2.0
 * Author:      ALFa Quantum Dynamics
 * License:     GPL-2.0-or-later
 */

if (!defined('ABSPATH')) {
    exit;
}

class Alfa_Site_Chrome {

    const VERSION = '1.2.0';

    private const TAGLINE = 'Where Speed meets Innovation and Quality is Always ALFa';

    public function __construct() {
        add_action('wp_enqueue_scripts', [$this, 'enqueue_assets']);
        add_filter('body_class', [$this, 'body_class']);
        add_action('wp_body_open', [$this, 'render_top_nav'], 5);
        add_action('wp_body_open', [$this, 'render_inner_page_chrome'], 8);
        add_filter('the_content', [$this, 'wrap_page_content'], 12);
        add_action('init', [$this, 'disable_legacy_test_tagline'], 20);
        add_filter('render_block', [$this, 'filter_blocks'], 10, 2);
    }

    public function disable_legacy_test_tagline(): void {
        remove_action('wp_footer', 'market_bot_test_footer', 1);
    }

    /** @param array<int, string> $classes */
    public function body_class(array $classes): array {
        if (!is_admin()) {
            $classes[] = 'alfa-site-unified';
        }
        return $classes;
    }

    public function enqueue_assets(): void {
        if (is_admin()) {
            return;
        }
        $css = dirname(__FILE__) . '/alfa-site-chrome.css';
        $url = content_url('mu-plugins/alfa-site-chrome.css');
        if (!file_exists($css)) {
            return;
        }
        wp_register_style('alfa-site-chrome', $url, [], self::VERSION);
        wp_enqueue_style('alfa-site-chrome');
    }

    /** @param array<string, mixed> $block */
    public function filter_blocks(string $block_content, array $block): string {
        $name = $block['blockName'] ?? '';

        if ($name === 'core/template-part') {
            $slug = $block['attrs']['slug'] ?? '';
            if ($slug === 'header') {
                return '';
            }
            if ($slug === 'footer') {
                return $this->minimal_footer_html();
            }
            return $block_content;
        }

        if ($name === 'core/pattern') {
            $slug = $block['attrs']['slug'] ?? '';
            if ($slug === 'spectra-one/hero-page') {
                return '';
            }
        }

        if ($name === 'core/post-featured-image' && $this->should_apply_inner_layout()) {
            return '';
        }

        return $block_content;
    }

    private function minimal_footer_html(): string {
        $text = 'Website created and self hosted by example N Alfrey Jr.';
        return sprintf(
            '<footer class="wp-block-template-part alfa-site-chrome-footer"><p class="alfa-site-chrome-footer__credit">%s</p></footer>',
            esc_html($text)
        );
    }

    public function render_top_nav(): void {
        if (is_admin()) {
            return;
        }

        $links = [
            ['label' => 'Home', 'url' => home_url('/')],
            ['label' => 'About', 'url' => home_url('/about/')],
            ['label' => 'Projects', 'url' => home_url('/projects/')],
            ['label' => 'Blog', 'url' => home_url('/blog/')],
            ['label' => 'Contact', 'url' => home_url('/contact/')],
        ];

        ?>
        <header class="alfa-site-chrome-header" role="banner">
            <div class="alfa-site-chrome-header__inner">
                <nav class="alfa-site-chrome-header__nav" aria-label="Primary">
                    <?php foreach ($links as $link) : ?>
                        <?php $active = $this->nav_link_is_current($link['url']); ?>
                        <a<?php echo $active ? ' class="is-active"' : ''; ?> href="<?php echo esc_url($link['url']); ?>"><?php echo esc_html($link['label']); ?></a>
                    <?php endforeach; ?>
                </nav>
            </div>
        </header>
        <?php
    }

    public function render_inner_page_chrome(): void {
        if (is_admin() || is_home() || is_front_page()) {
            return;
        }
        if (!$this->should_apply_inner_layout()) {
            return;
        }

        $this->render_brand_bar();

        $title = '';
        if (is_singular()) {
            $title = get_the_title();
        } elseif (is_archive()) {
            $title = get_the_archive_title();
        }

        ?>
        <div class="alfa-site-page-intro">
            <p class="alfa-site-page-intro__tagline"><?php echo esc_html(self::TAGLINE); ?></p>
            <?php if ($title !== '') : ?>
                <h1 class="alfa-site-page-intro__title"><?php echo esc_html(wp_strip_all_tags($title)); ?></h1>
            <?php endif; ?>
        </div>
        <?php
    }

    private function render_brand_bar(): void {
        ?>
        <div class="alfa-site-brand-bar" role="presentation">
            <h4><em>ALFa Quantum Dynamics</em> (ALFaQD)</h4>
        </div>
        <?php
    }

    public function wrap_page_content(string $content): string {
        if (!$this->should_apply_inner_layout()) {
            return $content;
        }
        if (!in_the_loop() || !is_main_query()) {
            return $content;
        }
        if (trim($content) === '') {
            return $content;
        }

        return '<div class="alfa-site-page"><div class="alfa-site-page__inner"><div class="alfa-site-page__panel">' . $content . '</div></div></div>';
    }

    private function should_apply_inner_layout(): bool {
        if (is_admin() || is_home() || is_front_page()) {
            return false;
        }
        return is_singular(['page', 'post']) || is_archive();
    }

    private function nav_link_is_current(string $url): bool {
        $path = (string) parse_url($url, PHP_URL_PATH);
        $req = isset($_SERVER['REQUEST_URI']) ? wp_unslash($_SERVER['REQUEST_URI']) : '/';
        $req_path = (string) parse_url($req, PHP_URL_PATH);
        $path = trailingslashit($path ?: '/');
        $req_path = trailingslashit($req_path ?: '/');

        if ($path === '/') {
            return $req_path === '/';
        }

        return str_starts_with($req_path, $path);
    }
}

new Alfa_Site_Chrome();
