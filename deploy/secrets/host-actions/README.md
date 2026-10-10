# Secrets on the operator machine

Store SSH private keys, Home Assistant long-lived tokens, LiteLLM keys, and database passwords on
the **operator machine only**. Do not commit secret files to git. Mount or copy them at deploy time.
