<?php
/**
 * DEPRECATED — WPBot removed; do not activate. Kept in repo for reference only.
 * Plugin Name: Chatbot Product Intelligence
 * Description: Enhances chatbot with detailed product information and intelligent responses
 * Version: 1.0
 * Author: ALFA System
 */

if ( ! defined( 'ABSPATH' ) ) {
    exit;
}

// Prevent duplicate loading
if ( defined( 'CHATBOT_PRODUCT_INTELLIGENCE_LOADED' ) ) {
    return;
}
define( 'CHATBOT_PRODUCT_INTELLIGENCE_LOADED', true );

/**
 * Get product information with enhanced details
 */
function chatbot_get_product_knowledge() {
    $products = array(
        'market' => array(
            'name'           => 'Market Bot',
            'url'            => 'https://market-bot.example.com/',
            'short_desc'     => 'AI-powered trading with self-scaling strategies',
            'full_desc'      => 'Market Bot is an advanced AI-powered trading platform designed for serious traders. It features self-scaling trading strategies that adapt to market conditions, intelligent risk management, real-time portfolio analysis, and predictive analytics using machine learning. Perfect for both beginners and experienced traders.',
            'features'       => array(
                'Self-scaling AI strategies',
                'Real-time market analysis',
                'Portfolio tracking & optimization',
                'Risk management tools',
                'Machine learning predictions',
                'Custom strategy builder',
            ),
            'benefits'       => 'Automated, intelligent trading decisions. Reduce emotion from trading. Scale strategies based on market volatility.',
            'keywords'       => array( 'trading', 'market', 'ai', 'bot', 'trading bot', 'trading platform', 'strategies', 'portfolio' ),
        ),
        'atems' => array(
            'name'           => 'ATEMS',
            'url'            => 'https://example.com/app/atems',
            'short_desc'     => 'Automated Tool & Equipment Management System',
            'full_desc'      => 'ATEMS is a comprehensive automated system for managing tools, equipment, and assets across your organization. It provides inventory tracking, maintenance scheduling, asset lifecycle management, depreciation calculations, and comprehensive reporting. Designed to optimize equipment utilization and reduce operational costs.',
            'features'       => array(
                'Complete inventory management',
                'Automated maintenance scheduling',
                'Asset lifecycle tracking',
                'Equipment depreciation calculations',
                'Multi-location support',
                'Comprehensive reporting & analytics',
                'Barcode/QR code integration',
            ),
            'benefits'       => 'Reduce equipment downtime. Optimize asset utilization. Streamline maintenance operations. Improve accountability.',
            'keywords'       => array( 'equipment', 'asset', 'management', 'inventory', 'maintenance', 'tracking', 'atems' ),
        ),
        'contracts' => array(
            'name'           => 'Contracts Bot',
            'url'            => 'https://contracts-bot.example.com/',
            'short_desc'     => 'Smart contracts monitoring and management',
            'full_desc'      => 'Contracts Bot is an intelligent contract management platform that monitors, tracks, and manages all your contracts in one secure location. Features include automated renewal alerts, compliance tracking, contract analysis, digital signatures, e-signature integration, and detailed audit trails. Keep track of obligations, deadlines, and contract values effortlessly.',
            'features'       => array(
                'Centralized contract repository',
                'Automated renewal reminders',
                'Compliance tracking & alerts',
                'Contract analytics & search',
                'Digital signature integration',
                'Detailed audit trails',
                'Obligation & deadline tracking',
            ),
            'benefits'       => 'Never miss a contract renewal. Ensure compliance across all agreements. Reduce legal risks. Improve contract visibility.',
            'keywords'       => array( 'contracts', 'contract management', 'monitoring', 'compliance', 'renewal', 'agreements', 'obligations' ),
        ),
        'credit_check' => array(
            'name'           => 'Credit Check Bot',
            'url'            => 'https://credit-check-bot.example.com/',
            'short_desc'     => 'Credit risk assessment and reseller tax compliance',
            'full_desc'      => 'Credit Check Bot provides comprehensive credit risk assessment and reseller tax compliance solutions. Verify customer creditworthiness, manage credit limits, track payment history, assess reseller tax applicability, and generate compliance reports. Essential for B2B businesses managing customer credit exposure.',
            'features'       => array(
                'Real-time credit verification',
                'Customer credit scoring',
                'Payment history tracking',
                'Reseller tax compliance',
                'Credit limit management',
                'Risk assessment reports',
                'Fraud detection',
                'Automated compliance workflows',
            ),
            'benefits'       => 'Reduce credit risk exposure. Ensure tax compliance. Make informed credit decisions. Speed up customer onboarding.',
            'keywords'       => array( 'credit', 'credit check', 'risk', 'compliance', 'tax', 'reseller', 'verification', 'assessment' ),
        ),
    );

    // Filter out hidden products (for admin reference)
    return $products;
}

/**
 * Get visible products only (excluding hidden ones)
 */
function chatbot_get_visible_products() {
    $all_products = chatbot_get_product_knowledge();
    $visible_products = array();

    // Get hidden bots from market-bot-responsive-grid plugin
    $hidden = function_exists( 'market_bot_get_hidden_bots' ) 
        ? market_bot_get_hidden_bots() 
        : array();

    foreach ( $all_products as $key => $product ) {
        if ( ! in_array( $key, $hidden, true ) ) {
            $visible_products[ $key ] = $product;
        }
    }

    return $visible_products;
}

/**
 * Detect if user is asking about products
 */
function chatbot_detect_product_question( $message ) {
    if ( empty( $message ) ) {
        return null;
    }

    $message_lower = strtolower( $message );
    $products = chatbot_get_product_knowledge();

    // Check for product names and keywords
    foreach ( $products as $key => $product ) {
        $keywords = array_merge(
            array( $product['name'], $key ),
            explode( ' ', strtolower( $product['short_desc'] ) ),
            $product['keywords']
        );

        foreach ( $keywords as $keyword ) {
            if ( ! empty( $keyword ) && strpos( $message_lower, strtolower( trim( $keyword ) ) ) !== false ) {
                return $key;
            }
        }
    }

    // Check for generic product/feature questions
    if ( preg_match( '/what.*products|what.*services|tell.*about|features|which.*bot/i', $message ) ) {
        return 'all_products';
    }

    return null;
}

/**
 * Generate intelligent chatbot response about products
 */
function chatbot_generate_product_response( $product_key ) {
    $all_products = chatbot_get_product_knowledge();
    $visible_products = chatbot_get_visible_products();

    if ( $product_key === 'all_products' ) {
        // List all visible products
        $response = "\n🤖 **ALFA's Software Solutions**\n\nWe offer several powerful tools for business automation:\n\n";

        foreach ( $visible_products as $key => $product ) {
            $response .= "**" . $product['name'] . "** - " . $product['short_desc'] . "\n";
            $response .= "→ " . $product['url'] . "\n\n";
        }

        $response .= "Would you like to know more about any of these solutions? Just ask! 😊";
        return $response;
    }

    if ( ! isset( $all_products[ $product_key ] ) ) {
        return null;
    }

    // If product is hidden, don't provide detailed info
    if ( ! isset( $visible_products[ $product_key ] ) ) {
        return "I don't have information about that product at the moment. Please check our other available solutions.";
    }

    $product = $all_products[ $product_key ];

    $response = "\n📊 **" . $product['name'] . "**\n\n";
    $response .= $product['full_desc'] . "\n\n";
    $response .= "**Key Features:**\n";

    foreach ( $product['features'] as $feature ) {
        $response .= "✓ " . $feature . "\n";
    }

    $response .= "\n**Benefits:** " . $product['benefits'] . "\n\n";
    $response .= "**Get Started:** " . $product['url'] . "\n\n";
    $response .= "Have more questions about " . $product['name'] . "? I'm here to help! 🚀";

    return $response;
}

/**
 * Hook into chatbot's AJAX request handler to enhance responses
 */
function chatbot_enhance_response() {
    if ( ! isset( $_POST['message'] ) ) {
        return;
    }

    $user_message = sanitize_text_field( $_POST['message'] );
    $product_key = chatbot_detect_product_question( $user_message );

    if ( null !== $product_key ) {
        $response = chatbot_generate_product_response( $product_key );

        if ( $response ) {
            // Store in session or transient for chatbot to use
            if ( ! isset( $_SESSION ) ) {
                session_start();
            }
            $_SESSION['chatbot_product_response'] = $response;
            $_SESSION['chatbot_product_detected'] = true;
        }
    }
}
add_action( 'wp_ajax_get_chatbot_response', 'chatbot_enhance_response', 5 );
add_action( 'wp_ajax_nopriv_get_chatbot_response', 'chatbot_enhance_response', 5 );

/**
 * Add product information to chatbot training/responses database
 * This runs once to seed the chatbot with smart sample responses
 */
function chatbot_add_initial_responses() {
    //  only run once
    if ( get_option( 'chatbot_product_intel_initialized' ) ) {
        return;
    }

    global $wpdb;
    $table = $wpdb->prefix . 'wpbot_response';

    if ( ! $wpdb->get_var( "SHOW TABLES LIKE '$table'" ) ) {
        return; // Table doesn't exist, plugin not active
    }

    $products = chatbot_get_product_knowledge();
    $visible_products = chatbot_get_visible_products();

    // Add training responses for each visible product
    foreach ( $visible_products as $key => $product ) {
        // Add response for product name query
        $wpdb->insert(
            $table,
            array(
                'statement'    => $product['name'],
                'response'     => chatbot_generate_product_response( $key ),
                'author'       => 'chatbot_product_intel',
                'createdtime'  => current_time( 'Y-m-d H:i:s' ),
            )
        );

        // Add response for keyword queries
        $keywords = array_slice( $product['keywords'], 0, 3 );
        foreach ( $keywords as $keyword ) {
            $wpdb->insert(
                $table,
                array(
                    'statement'    => ucwords( $keyword ) . ' ' . $key,
                    'response'     => "You're asking about " . $product['name'] . "? Great choice! " . $product['short_desc'] . " Learn more: " . $product['url'],
                    'author'       => 'chatbot_product_intel',
                    'createdtime'  => current_time( 'Y-m-d H:i:s' ),
                )
            );
        }
    }

    // Add a general products inquiry response
    $general_response = chatbot_generate_product_response( 'all_products' );
    $wpdb->insert(
        $table,
        array(
            'statement'    => 'What products do you offer',
            'response'     => $general_response,
            'author'       => 'chatbot_product_intel',
            'createdtime'  => current_time( 'Y-m-d H:i:s' ),
        )
    );

    update_option( 'chatbot_product_intel_initialized', true );
}

// Initialize on admin page load
add_action( 'admin_init', 'chatbot_add_initial_responses', 15 );

// Also initialize on front-end if not already done
add_action( 'wp_head', function() {
    if ( ! is_admin() && ! get_option( 'chatbot_product_intel_initialized' ) ) {
        chatbot_add_initial_responses();
    }
}, 1 );

/**
 * Enqueue script to enhance chatbot messages with product info
 */
function chatbot_product_intel_enqueue_frontend() {
    if ( ! is_front_page() && ! is_home() ) {
        return;
    }

    wp_enqueue_script( 'chatbot-product-intel', '', array( 'jquery' ), '1.0', true );
    wp_add_inline_script(
        'chatbot-product-intel',
        "
        jQuery(document).ready(function($) {
            // Enhance chatbot messages with product cards
            var originalAjax = $.ajax;
            $.ajax = function(options) {
                var originalSuccess = options.success;
                if (options.data && options.data.includes('get_chatbot_response')) {
                    options.success = function(response) {
                        // Check if we have a product response
                        if (window.chatbotProductResponse) {
                            response = window.chatbotProductResponse;
                            delete window.chatbotProductResponse;
                        }
                        if (originalSuccess) {
                            originalSuccess(response);
                        }
                    };
                }
                return originalAjax(options);
            };
        });
        "
    );
}
add_action( 'wp_enqueue_scripts', 'chatbot_product_intel_enqueue_frontend', 8 );

/**
 * Admin notice about product intelligence
 */
function chatbot_product_intel_admin_notice() {
    if ( ! current_user_can( 'manage_options' ) ) {
        return;
    }

    if ( get_transient( 'chatbot_product_intel_notice' ) ) {
        return;
    }

    ?>
    <div class="notice notice-success is-dismissible">
        <p><strong>Chatbot Enhanced:</strong> Product Intelligence module is active. Your chatbot now has detailed knowledge about all ALFA products and will provide smart responses about Market Bot, ATEMS, Contracts Bot, and Credit Check Bot. Responses respect product visibility settings.</p>
    </div>
    <?php
    set_transient( 'chatbot_product_intel_notice', 1, 7 * 24 * HOUR_IN_SECONDS );
}
add_action( 'admin_notices', 'chatbot_product_intel_admin_notice' );

/**
 * Deactivation cleanup
 */
function chatbot_product_intel_deactivate() {
    delete_option( 'chatbot_product_intel_initialized' );
}
register_deactivation_hook( __FILE__, 'chatbot_product_intel_deactivate' );
