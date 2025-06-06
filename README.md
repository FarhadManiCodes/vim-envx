# vim-envx

**vim-envx** is a lightweight Vim plugin to help with expanding and creating environment variable expressions. It provides intuitive mappings to:

- Expand `$VAR` and `${VAR}` inline  
- Expand all variables on the current line  
- Expand all variables in a visual selection  
- Extract selected text into a variable assignment above  

## Features

- 🪄 Expand environment variables under cursor  
- ✂️ Extract part of text into `$VAR` and assign value above  
- 📜 Expand all variables in a line or selection  
- 🧠 Smart handling of `$VAR` vs `${VAR}` formats  

## Installation

Using [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'FarhadManiCodes/vim-envx'
```

Then run `:PlugInstall`.

## Mappings

| Mode | Mapping         | Action                                      |
|-------|-----------------|---------------------------------------------|
| Normal (`n`)  | `<leader>ev`     | Expand environment variable under cursor     |
| Normal (`n`)  | `<leader>eev`    | Expand all environment variables on line     |
| Visual (`x`)  | `<leader>ev`     | Expand all environment variables in visual   |
| Visual (`x`)  | `<leader>evv`    | Extract selected text as env variable        |

## Example

If you have:

```bash
cd $HOME/Downloads
```

Pressing `<leader>ev` on `$HOME` will replace it with `/home/yourname`.

To extract `"Downloads"` into a variable:

1. Select the word in visual mode.  
2. Press `<leader>evv`.  
3. Type your variable name (e.g., `MYDIR`).  
4. The line above becomes:

   ```bash
   MYDIR="Downloads"
   ```

And the selected text in your code becomes `$MYDIR`.

## License

MIT
