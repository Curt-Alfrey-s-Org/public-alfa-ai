import subprocess, sys

subprocess.check_call([sys.executable, '-m', 'pip', 'install', '-q', 'tokenizers>=0.20,<0.21'])

dep_table = '/usr/local/lib/python3.12/site-packages/transformers/dependency_versions_table.py'
with open(dep_table) as f:
    content = f.read()
old = '"tokenizers>=0.19,<0.20"'
new = '"tokenizers>=0.19"'
with open(dep_table, 'w') as f:
    f.write(content.replace(old, new))

import tokenizers; print('tokenizers', tokenizers.__version__)
from transformers import AutoTokenizer
tok = AutoTokenizer.from_pretrained('meta-llama/Llama-3.3-70B-Instruct')
print('Tokenizer loaded OK:', type(tok).__name__)
