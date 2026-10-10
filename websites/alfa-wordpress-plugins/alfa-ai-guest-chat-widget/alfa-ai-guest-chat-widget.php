<?php
/**
 * Plugin Name: ALFa AI Guest Chat Widget
 * Description: Canonical public chat for all ALFa WordPress sites. Calls same-origin
 *   POST /alfa-ai/api/guest/chat (proxied to alfa-ai-api on tunnel_network).
 *   Replaces legacy WPBot. Shortcode: [alfa_ai_chat]. Floating FAB when enabled.
 * Version:     1.4.0
 * Author:      ALFa Quantum Dynamics
 * License:     GPL-2.0-or-later
 *
 * Same backend as example-siteperch.com and the alfa-ai GuestChat SPA — one guest API.
 * Signed-in bot apps (contracts-bot, etc.) use /api/ai-narrative/ask instead.
 */

if (!defined('ABSPATH')) {
    exit;
}

class Alfa_Ai_Guest_Chat_Widget {

    const VERSION = '1.4.0';
    const ALFA_AI_ENDPOINT = '/alfa-ai/api/guest/chat';
    const OPTION_FLOATING = 'alfa_ai_chat_floating';
    const CORPUS_TRANSIENT = 'alfa_ai_site_corpus';
    const CORPUS_MAX_CHARS = 12000;
    const GUEST_MAX_MESSAGES = 6;

    public function __construct() {
        add_shortcode('alfa_ai_chat', [$this, 'render_shortcode']);
        add_action('wp_enqueue_scripts', [$this, 'register_assets']);
        add_action('wp_footer', [$this, 'maybe_render_floating'], 20);
        add_action('admin_init', [$this, 'register_settings']);
        add_action('admin_menu', [$this, 'settings_page']);
        add_filter('template_include', [$this, 'maybe_popup_template'], 99);
        add_filter('body_class', [$this, 'maybe_popup_body_class']);
        add_action('save_post', [$this, 'invalidate_site_corpus']);
        add_action('deleted_post', [$this, 'invalidate_site_corpus']);
        add_action('trashed_post', [$this, 'invalidate_site_corpus']);
    }

    public function is_popup_request(): bool {
        return isset($_GET['alfa_ai_popup']) && (string) $_GET['alfa_ai_popup'] === '1';
    }

    /**
     * Chat-only document for window.open(..., 520x720).
     * Official: template_include, not template_redirect + exit.
     * https://developer.wordpress.org/reference/hooks/template_include/
     *
     * @param string $template
     * @return string
     */
    public function maybe_popup_template($template) {
        if (!$this->is_popup_request()) {
            return $template;
        }
        $popup = __DIR__ . '/popup-template.php';
        if (is_readable($popup)) {
            return $popup;
        }
        return $template;
    }

    /**
     * @param string[] $classes
     * @return string[]
     */
    public function maybe_popup_body_class(array $classes): array {
        if ($this->is_popup_request()) {
            $classes[] = 'alfa-ai-chat-popup';
        }
        return $classes;
    }

    public function register_settings() {
        register_setting('alfa_ai_chat', self::OPTION_FLOATING, [
            'type'              => 'boolean',
            'default'           => true,
            'sanitize_callback' => static function ($v) {
                return (bool) $v;
            },
        ]);
    }

    public function settings_page() {
        add_options_page(
            'ALFa AI Chat',
            'ALFa AI Chat',
            'manage_options',
            'alfa-ai-chat',
            [$this, 'render_settings']
        );
    }

    public function render_settings() {
        if (!current_user_can('manage_options')) {
            return;
        }
        ?>
        <div class="wrap">
            <h1>ALFa AI Guest Chat</h1>
            <p>Uses <code><?php echo esc_html(self::ALFA_AI_ENDPOINT); ?></code> via site nginx → <code>alfa-ai-api:8000</code>.</p>
            <form method="post" action="options.php">
                <?php settings_fields('alfa_ai_chat'); ?>
                <table class="form-table">
                    <tr>
                        <th>Floating chat button</th>
                        <td>
                            <label>
                                <input type="checkbox" name="<?php echo esc_attr(self::OPTION_FLOATING); ?>" value="1"
                                    <?php checked(get_option(self::OPTION_FLOATING, true)); ?> />
                                Show bottom-right chat on all public pages
                            </label>
                        </td>
                    </tr>
                </table>
                <?php submit_button(); ?>
            </form>
            <p>Embed manually: <code>[alfa_ai_chat]</code></p>
        </div>
        <?php
    }

    public function register_assets() {
        $needs_assets = $this->floating_enabled()
            || $this->is_popup_request()
            || (is_singular() && has_shortcode(get_post()->post_content ?? '', 'alfa_ai_chat'));

        if (!$needs_assets) {
            return;
        }

        wp_register_style(
            'alfa-ai-guest-chat',
            plugins_url('alfa-ai-chat-widget.css', __FILE__),
            [],
            self::VERSION
        );
        wp_register_script(
            'alfa-ai-guest-chat',
            plugins_url('alfa-ai-chat-widget.js', __FILE__),
            [],
            self::VERSION,
            true
        );
        wp_localize_script('alfa-ai-guest-chat', 'ALFA_AI_CHAT', $this->client_config());
        wp_enqueue_style('alfa-ai-guest-chat');
        wp_enqueue_script('alfa-ai-guest-chat');
        if (function_exists('wp_script_add_data')) {
            wp_script_add_data('alfa-ai-guest-chat', 'strategy', 'defer');
        }
    }

    private function floating_enabled(): bool {
        return (bool) get_option(self::OPTION_FLOATING, true);
    }

    /** @return array<string, mixed> */
    private function client_config(): array {
        return [
            'alfaAiEndpoint' => self::ALFA_AI_ENDPOINT,
            'relayEndpoint'  => apply_filters('alfa_ai_chat_relay_endpoint', ''),
            'relayToken'     => apply_filters('alfa_ai_chat_relay_token', ''),
            'primer'         => $this->build_primer(),
            'guestMaxMessages' => self::GUEST_MAX_MESSAGES,
            'nonce'          => wp_create_nonce('wp_rest'),
            'popupQuery'     => 'alfa_ai_popup=1',
            'isPopup'        => $this->is_popup_request() ? '1' : '',
            'avatarUrl'      => apply_filters(
                'alfa_ai_chat_avatar_url',
                'https://www.example.com/alfa-ai/branding/alfa-ai-avatar.png'
            ),
        ];
    }

    public function invalidate_site_corpus(): void {
        delete_transient(self::CORPUS_TRANSIENT);
    }

    /**
     * Published pages/posts of THIS WordPress site only.
     * get_pages: https://developer.wordpress.org/reference/functions/get_pages/
     * get_posts: https://developer.wordpress.org/reference/functions/get_posts/
     * wp_strip_all_tags: https://developer.wordpress.org/reference/functions/wp_strip_all_tags/
     * set_transient: https://developer.wordpress.org/reference/functions/set_transient/
     */
    private function site_corpus(): string {
        $cached = get_transient(self::CORPUS_TRANSIENT);
        if (is_string($cached) && $cached !== '') {
            return $cached;
        }

        $home = home_url('/');
        $parts = [];
        $parts[] = 'Site title: ' . get_bloginfo('name');
        $parts[] = 'Tagline: ' . get_bloginfo('description');
        $parts[] = 'Home URL: ' . $home;

        $pages = get_pages([
            'post_status' => 'publish',
            'number'      => 40,
            'sort_column' => 'menu_order,post_title',
        ]);
        if (is_array($pages)) {
            foreach ($pages as $page) {
                $block = $this->format_entry_for_corpus($page);
                if ($block !== '') {
                    $parts[] = $block;
                }
            }
        }

        $posts = get_posts([
            'post_type'      => 'post',
            'post_status'    => 'publish',
            'numberposts'    => 20,
            'orderby'        => 'date',
            'order'          => 'DESC',
            'suppress_filters' => true,
        ]);
        if (is_array($posts)) {
            foreach ($posts as $post) {
                $block = $this->format_entry_for_corpus($post);
                if ($block !== '') {
                    $parts[] = $block;
                }
            }
        }

        $text = implode("\n\n", $parts);
        if (strlen($text) > self::CORPUS_MAX_CHARS) {
            $text = substr($text, 0, self::CORPUS_MAX_CHARS) . "\n[truncated]";
        }
        if ($text === '') {
            $text = 'No published pages or posts were found on this site.';
        }
        set_transient(self::CORPUS_TRANSIENT, $text, 15 * MINUTE_IN_SECONDS);
        return $text;
    }

    /**
     * @param \WP_Post $entry
     */
    private function format_entry_for_corpus($entry): string {
        if (!is_object($entry) || empty($entry->post_title)) {
            return '';
        }
        if (!empty($entry->post_password)) {
            return '';
        }
        $body = wp_strip_all_tags((string) $entry->post_content, true);
        $body = html_entity_decode($body, ENT_QUOTES | ENT_HTML5, 'UTF-8');
        $body = trim(preg_replace('/\s+/u', ' ', $body) ?? $body);
        if ($body === '') {
            return '';
        }
        if (strlen($body) > 2500) {
            $body = substr($body, 0, 2500) . '...';
        }
        $url = get_permalink($entry);
        $url = is_string($url) ? $url : '';
        return 'Title: ' . $entry->post_title . "\nURL: " . $url . "\nBody: " . $body;
    }

    /** @return array<int, array{role: string, content: string}> */
    private function build_primer(): array {
        $site_name = get_bloginfo('name');
        $home = home_url('/');
        $corpus = $this->site_corpus();

        $instructions = apply_filters(
            'alfa_ai_chat_primer_instructions',
            'You are the public assistant for THIS website only (' . $site_name . ' at ' . $home . ").\n"
            . "Answer ONLY from the published pages and posts below. They are the content of this site.\n"
            . "If the answer is not in that text, say you do not have it on this site. If a Contact page is listed, point there.\n"
            . "Do not mention other ALFa products, apps, or subdomains unless they appear in the pages below.\n"
            . "Do not invent pricing, people, SLAs, or features. Do not name the underlying model.\n"
            . "Be concise (2-4 sentences). Refuse legal, medical, and investment advice.\n\n"
            . "PUBLISHED SITE CONTENT:\n\n"
        );

        return [
            ['role' => 'system', 'content' => $instructions . $corpus],
        ];
    }

    /** @param array<string, string> $atts */
    public function render_shortcode($atts) {
        $atts = shortcode_atts([
            'title'       => 'ALFa AI',
            'subtitle'    => 'Questions about our products and this website',
            'placeholder' => 'Ask about our software and products...',
        ], $atts, 'alfa_ai_chat');

        return $this->chat_html($atts['title'], $atts['subtitle'], $atts['placeholder'], '', false);
    }

    public function maybe_render_floating() {
        if (!$this->floating_enabled() || is_admin()) {
            return;
        }
        $popup = $this->is_popup_request();
        $panel_open = $popup ? ' is-open' : '';
        $dock_open = $popup ? ' is-panel-open' : '';
        echo '<div class="alfa-ai-dock' . esc_attr($dock_open) . '" id="alfa-ai-dock" aria-live="polite">';
        echo '<div id="alfa-ai-chat-panel" class="alfa-ai-chat-panel' . esc_attr($panel_open) . '" role="dialog" aria-label="ALFa AI" aria-hidden="' . ($popup ? 'false' : 'true') . '">';
        echo $this->chat_html(
            'ALFa AI',
            'Questions about this website',
            'Ask about this website...',
            ' alfa-ai-chat--float',
            true
        );
        echo '</div>';
        if (!$popup) {
            echo '<button type="button" id="alfa-ai-chat-fab" class="alfa-ai-chat-fab" aria-expanded="false" aria-controls="alfa-ai-chat-panel" title="Open ALFa AI">';
            $avatar = esc_url(apply_filters('alfa_ai_chat_avatar_url', 'https://www.example.com/alfa-ai/branding/alfa-ai-avatar.png'));
            echo '<img class="alfa-ai-chat-fab__badge" src="' . $avatar . '" alt="" width="36" height="36" />';
            echo '<span class="alfa-ai-chat-fab__label">ALFa AI</span>';
            echo '</button>';
        }
        echo '</div>';
    }

    private function chat_html(
        string $title,
        string $subtitle,
        string $placeholder,
        string $extra_class,
        bool $show_chrome = false
    ): string {
        $input_id = 'alfa-ai-chat-input-' . substr(md5($title . $placeholder), 0, 6);
        $avatar = esc_url(apply_filters('alfa_ai_chat_avatar_url', 'https://www.example.com/alfa-ai/branding/alfa-ai-avatar.png'));
        ob_start(); ?>
        <div class="alfa-ai-chat<?php echo esc_attr($extra_class); ?>">
            <div class="alfa-ai-chat__header">
                <img class="alfa-ai-chat__avatar" src="<?php echo $avatar; ?>" alt="" width="28" height="28" />
                <div class="alfa-ai-chat__header-text">
                    <span class="alfa-ai-chat__title"><?php echo esc_html($title); ?></span>
                    <p class="alfa-ai-chat__subtitle"><?php echo esc_html($subtitle); ?></p>
                </div>
                <?php if ($show_chrome) : ?>
                <div class="alfa-ai-chat__header-actions">
                    <button type="button" class="alfa-ai-chat__icon-btn alfa-ai-chat__popup" id="alfa-ai-chat-popup" title="Open in popup window" aria-label="Open in popup window">&#x29C9;</button>
                    <button type="button" class="alfa-ai-chat__icon-btn alfa-ai-chat__fullscreen" id="alfa-ai-chat-fullscreen" title="Full screen" aria-label="Full screen">&#x26F6;</button>
                    <button type="button" class="alfa-ai-chat__icon-btn alfa-ai-chat__close" aria-label="Close ALFa AI">&#x2715;</button>
                </div>
                <?php endif; ?>
            </div>
            <div class="alfa-ai-chat__body">
                <div class="alfa-ai-chat__log" aria-live="polite"></div>
                <form class="alfa-ai-chat__form" autocomplete="off">
                    <label class="screen-reader-text" for="<?php echo esc_attr($input_id); ?>">Message</label>
                    <div class="alfa-ai-chat__input-row">
                        <textarea class="alfa-ai-chat__input" maxlength="500" required rows="1"
                            placeholder="<?php echo esc_attr($placeholder); ?>"
                            id="<?php echo esc_attr($input_id); ?>"></textarea>
                        <button type="submit" class="alfa-ai-chat__send" aria-label="Send message">
                            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" width="20" height="20" aria-hidden="true"><path d="M3.105 2.289a.75.75 0 00-.826.95l1.414 4.925A1.5 1.5 0 005.135 9.25h6.115a.75.75 0 010 1.5H5.135a1.5 1.5 0 00-1.442 1.086l-1.414 4.926a.75.75 0 00.826.95 28.896 28.896 0 0015.293-7.154.75.75 0 000-1.115A28.897 28.897 0 003.105 2.289z"/></svg>
                        </button>
                    </div>
                    <p class="alfa-ai-chat__hint">Enter to send · Shift+Enter for newline</p>
                </form>
                <p class="alfa-ai-chat__footer">Rate-limited. Do not share passwords or payment info.</p>
            </div>
        </div>
        <?php
        return (string) ob_get_clean();
    }
}

new Alfa_Ai_Guest_Chat_Widget();
