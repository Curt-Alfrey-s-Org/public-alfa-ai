<?php
/**
 * Plugin Name: Market Bot Responsive Grid
 * Description: Deprecated — bot grid moved to /projects/ (alfa-projects-portfolio). Admin toggle hooks retained for legacy.
 * Version: 1.7
 */

// Prevent duplicate output if plugin is loaded twice (e.g. mu-plugins + plugins)
if ( defined( 'MARKET_BOT_RESPONSIVE_GRID_LOADED' ) ) {
    return;
}
define( 'MARKET_BOT_RESPONSIVE_GRID_LOADED', true );

// Output CSS on front page only
function market_bot_responsive_grid_styles() {
    // Grid moved to /projects/ — no homepage styles needed.
    return;
}
add_action( 'wp_head', 'market_bot_responsive_grid_styles', 5 );

// Get list of hidden bots from WordPress option
function market_bot_get_hidden_bots() {
    $hidden = get_option( 'market_bot_hidden_list', array() );
    return is_array( $hidden ) ? $hidden : array();
}

// Check if a specific bot is hidden
function market_bot_is_hidden( $bot_name ) {
    $hidden = market_bot_get_hidden_bots();
    return in_array( $bot_name, $hidden, true );
}

// AJAX handler to toggle bot visibility
function market_bot_toggle_visibility() {
    if ( ! is_user_logged_in() || ! current_user_can( 'manage_options' ) ) {
        wp_send_json_error( 'Not authorized', 403 );
    }
    
    if ( ! isset( $_POST['nonce'] ) || ! wp_verify_nonce( $_POST['nonce'], 'market_bot_nonce' ) ) {
        wp_send_json_error( 'Invalid nonce', 400 );
    }
    
    $bot_name = isset( $_POST['bot_name'] ) ? sanitize_text_field( $_POST['bot_name'] ) : '';
    if ( ! $bot_name ) {
        wp_send_json_error( 'No bot name provided', 400 );
    }
    
    $hidden = market_bot_get_hidden_bots();
    $key = array_search( $bot_name, $hidden, true );
    
    if ( $key !== false ) {
        // Bot is hidden, show it
        unset( $hidden[ $key ] );
        $is_hidden = false;
    } else {
        // Bot is visible, hide it
        $hidden[] = $bot_name;
        $is_hidden = true;
    }
    
    $hidden = array_values( $hidden ); // Re-index array
    update_option( 'market_bot_hidden_list', $hidden );
    
    wp_send_json_success( array( 'is_hidden' => $is_hidden, 'bot_name' => $bot_name ) );
}
add_action( 'wp_ajax_market_bot_toggle_visibility', 'market_bot_toggle_visibility' );

// Enqueue admin script and nonce
function market_bot_enqueue_admin_script() {
    if ( ! is_front_page() && ! is_home() ) {
        return;
    }
    
    if ( is_user_logged_in() && current_user_can( 'manage_options' ) ) {
        // Add class to body so CSS knows to show admin controls
        add_filter( 'body_class', function( $classes ) {
            $classes[] = 'market-bot-admin-view';
            return $classes;
        } );
        
        // Inline script for toggle functionality
        wp_add_inline_script( 'jquery', "
            jQuery(document).ready(function($) {
                $('.market-bot-admin-toggle').on('click', function(e) {
                    e.preventDefault();
                    var btn = $(this);
                    var botName = btn.data('bot-name');
                    var column = btn.closest('.market-bot-column');
                    
                    $.ajax({
                        url: ajaxurl,
                        type: 'POST',
                        data: {
                            action: 'market_bot_toggle_visibility',
                            nonce: '" . wp_create_nonce( 'market_bot_nonce' ) . "',
                            bot_name: botName
                        },
                        success: function(response) {
                            if (response.success) {
                                var isHidden = response.data.is_hidden;
                                if (isHidden) {
                                    column.addClass('market-bot-hidden');
                                    btn.text('👁 Show');
                                } else {
                                    column.removeClass('market-bot-hidden');
                                    btn.text('👁‍🗨 Hide');
                                }
                            }
                        },
                        error: function(xhr, status, error) {
                            console.error('Error toggling bot visibility:', error);
                        }
                    });
                });
            });
        " );
    }
}
add_action( 'wp_enqueue_scripts', 'market_bot_enqueue_admin_script' );

// Grid HTML (reused for content injection)
function market_bot_responsive_grid_html() {
    $is_admin = is_user_logged_in() && current_user_can( 'manage_options' );
    
    // Define bots and their properties (in_work = greyed out, non-clickable)
    $bots = array(
        array(
            'name'    => 'Market',
            'key'     => 'market',
            'url'     => 'https://market-bot.example.com/',
            'desc'    => 'AI-powered trading with self-scaling strategies',
            'in_work' => true,
        ),
        array(
            'name'    => 'ATEMS',
            'key'     => 'atems',
            'url'     => 'https://example.com/app/atems',
            'desc'    => 'Automated Tool &amp; Equipment Management System',
            'in_work' => true,
        ),
        array(
            'name'    => 'Pro Billiards',
            'key'     => 'pro_billiards',
            'url'     => 'https://rankings-bot.example.com/',
            'desc'    => 'Tracking Bot for WPBA/WPA Official Player Rankings',
            'in_work' => true,
        ),
        array(
            'name'    => 'Contracts',
            'key'     => 'contracts',
            'url'     => 'https://contracts-bot.example.com/',
            'desc'    => 'Smart contracts monitoring and management',
            'in_work' => true,
        ),
        array(
            'name'    => 'Credit Check',
            'key'     => 'credit_check',
            'url'     => 'https://credit-check-bot.example.com/',
            'desc'    => 'Credit risk assessment and reseller tax compliance',
            'in_work' => true,
        ),
    );
    
    ob_start();
    ?>
    <div class="market-bot-grid-wrapper">
        <div class="market-bot-grid-header">Custom Software Developer</div>
        <div class="market-bot-grid-tagline" style="font-size: 14px; color: #999;">IN WORK</div>
        <div class="market-bot-grid-tagline">Two systems won't talk and the old one holds half your data? We'll bridge the gap.</div>
        <div class="market-bot-grid-subtagline">Whether it's custom software, gap software, or AI Asst.—we can help.</div>
        <div class="market-bot-grid-container">
            <?php
            foreach ( $bots as $bot ) {
                // Skip hidden bots unless admin is viewing
                if ( market_bot_is_hidden( $bot['key'] ) ) {
                    if ( ! $is_admin ) {
                        continue;
                    }
                }
                
                $hidden_class = market_bot_is_hidden( $bot['key'] ) ? 'market-bot-hidden' : '';
                $toggle_btn = '';
                
                if ( $is_admin ) {
                    $toggle_text = market_bot_is_hidden( $bot['key'] ) ? '👁 Show' : '👁‍🗨 Hide';
                    $toggle_btn = sprintf(
                        '<button type="button" class="market-bot-admin-toggle" data-bot-name="%s">%s</button>',
                        esc_attr( $bot['key'] ),
                        $toggle_text
                    );
                }
                $disabled_class = ! empty( $bot['in_work'] ) ? 'market-bot-disabled' : '';
                $btn_tag = ! empty( $bot['in_work'] ) ? 'span' : 'a';
                $btn_attrs = ( $btn_tag === 'a' ) ? ' href="' . esc_url( $bot['url'] ) . '"' : '';
                ?>
                <div class="market-bot-column <?php echo esc_attr( $hidden_class ); ?>">
                    <?php echo wp_kses_post( $toggle_btn ); ?>
                    <div class="bot-summary">
                        <div class="bot-summary-title"><?php echo esc_html( $bot['name'] ); ?></div>
                        <div class="bot-summary-desc"><?php echo esc_html( $bot['desc'] ); ?></div>
                    </div>
                    <<?php echo $btn_tag; ?><?php echo $btn_attrs; ?> class="market-bot-inline-btn <?php echo esc_attr( $disabled_class ); ?>"><?php echo esc_html( $bot['name'] ); ?></<?php echo $btn_tag; ?>>
                </div>
                <?php
            }
            ?>
        </div>
    </div>
    <?php
    return ob_get_clean();
}

// Bot grid moved to /projects/ — see alfa-projects-portfolio.php.
// Homepage no longer injects the product grid; use the Projects nav link instead.

