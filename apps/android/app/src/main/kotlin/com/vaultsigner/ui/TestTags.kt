package com.vaultsigner.ui

/**
 * Stable, locale-independent hooks for instrumented Compose UI tests
 * (spec item 4.8) — matching on visible text ties tests to exact i18n
 * copy, which changes independently of behavior and breaks per-locale
 * (`values-ar/strings.xml` runs the identical test differently for free
 * if it ever matched text; matching a tag doesn't have that problem).
 * Only the handful of elements an instrumented test actually needs to
 * find are tagged — this is not meant to cover every interactive element
 * in the app.
 */
object TestTags {
    const val WELCOME_CREATE_VAULT_BUTTON = "welcome_create_vault_button"
    const val CREATE_VAULT_FILENAME = "create_vault_filename"
    const val CREATE_VAULT_COMPARTMENT_LABEL = "create_vault_compartment_label"
    const val CREATE_VAULT_MASTER_PASSPHRASE = "create_vault_master_passphrase"
    const val CREATE_VAULT_CONFIRM_PASSPHRASE = "create_vault_confirm_passphrase"
    const val CREATE_VAULT_SUBMIT = "create_vault_submit"

    const val KEY_LIST_TITLE = "key_list_title"
    const val KEY_LIST_NEW_KEY_BUTTON = "key_list_new_key_button"
    const val KEY_LIST_NO_KEYS_TEXT = "key_list_no_keys_text"

    const val CREATE_KEY_LABEL = "create_key_label"
    const val CREATE_KEY_PASSPHRASE = "create_key_passphrase"
    const val CREATE_KEY_CONFIRM_PASSPHRASE = "create_key_confirm_passphrase"
    const val CREATE_KEY_SUBMIT = "create_key_submit"

    const val KEY_LIST_SETTINGS_BUTTON = "key_list_settings_button"
    const val KEY_LIST_MENU_BUTTON = "key_list_menu_button"
    const val KEY_LIST_EXPORT_MENU_ITEM = "key_list_export_menu_item"
    const val KEY_LIST_IMPORT_MENU_ITEM = "key_list_import_menu_item"
    const val KEY_LIST_NEW_COMPARTMENT_MENU_ITEM = "key_list_new_compartment_menu_item"

    const val CREATE_COMPARTMENT_LABEL = "create_compartment_label"
    const val CREATE_COMPARTMENT_PASSPHRASE = "create_compartment_passphrase"
    const val CREATE_COMPARTMENT_CONFIRM_PASSPHRASE = "create_compartment_confirm_passphrase"
    const val CREATE_COMPARTMENT_SUBMIT = "create_compartment_submit"

    // Shared by every key row's checkbox on ExportPacketScreen — not
    // unique per key, since a test only ever needs "the Nth key checkbox"
    // (onAllNodesWithTag(...)[n]), never a specific key by id.
    const val EXPORT_KEY_CHECKBOX = "export_key_checkbox"
    const val EXPORT_INCLUDE_MASTER_CHECKBOX = "export_include_master_checkbox"
    const val EXPORT_OPTION_ASIS = "export_option_asis"
    const val EXPORT_OPTION_DESTINATION = "export_option_destination"
    const val EXPORT_OPTION_TRANSFER = "export_option_transfer"
    const val EXPORT_SUBMIT = "export_submit"

    const val IMPORT_CHOOSE_FILE_BUTTON = "import_choose_file_button"

    const val DUALITY_OPTION1_PICKER_BUTTON = "duality_option1_picker_button"
    const val DUALITY_OPTION1_USE_BUTTON = "duality_option1_use_button"

    const val SETTINGS_CLOSE_VAULT_BUTTON = "settings_close_vault_button"
}
