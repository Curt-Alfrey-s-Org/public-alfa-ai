<?php
/**
 * Chat-only template for the 520x720 popup window.
 *
 * Loaded via template_include when ?alfa_ai_popup=1
 * https://developer.wordpress.org/reference/hooks/template_include/
 */
if (!defined('ABSPATH')) {
    exit;
}
?><!DOCTYPE html>
<html <?php language_attributes(); ?>>
<head>
    <meta charset="<?php bloginfo('charset'); ?>">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title><?php echo esc_html('ALFa AI'); ?></title>
    <?php wp_head(); ?>
    <style>
        html, body {
            margin: 0;
            height: 100%;
            background: #0a1838;
        }
        body.alfa-ai-chat-popup .alfa-ai-dock {
            inset: 0;
            width: 100%;
            height: 100%;
            max-width: none;
            align-items: stretch;
        }
        body.alfa-ai-chat-popup .alfa-ai-chat-panel {
            width: 100%;
            height: 100%;
            max-height: none;
            border-radius: 0;
        }
        body.alfa-ai-chat-popup .alfa-ai-chat-fab,
        body.alfa-ai-chat-popup .alfa-ai-chat__popup {
            display: none !important;
        }
    </style>
</head>
<body class="alfa-ai-chat-popup">
<?php
if (function_exists('wp_footer')) {
    wp_footer();
}
?>
</body>
</html>
