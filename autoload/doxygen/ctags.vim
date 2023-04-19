" Ctags module for doxygen

" Global Options {{{

let g:doxygen_auto_setup = 1
let g:doxygen_clone_config_repo = 'https://github.com/Zeioth/doxygenvim-template.git'
let g:doxygen_clone_cmd = 'git clone'
let g:doxygen_clone_subdir = ''

" Doxygen - KB Shortcuts
let g:doxygen_shortcut_run = ''
let g:doxygen_shortcut_generate = ''

" Doxygen - Autoregen
let g:doxygen_auto_regen = 1
let g:doxygen_cmd = "doxygen -g <config-file>"

" TODO: Use the one guttentags defined already
" g:project_root=".git"






let g:doxygen_ctags_executable = get(g:, 'doxygen_ctags_executable', 'ctags')


let g:doxygen_ctags_executable = get(g:, 'doxygen_ctags_executable', 'ctags')
let g:doxygen_ctags_tagfile = get(g:, 'doxygen_ctags_tagfile', 'tags')
let g:doxygen_ctags_auto_set_tags = get(g:, 'doxygen_ctags_auto_set_tags', 1)

let g:doxygen_ctags_options_file = get(g:, 'doxygen_ctags_options_file', '.gutctags')
let g:doxygen_ctags_check_tagfile = get(g:, 'doxygen_ctags_check_tagfile', 0)
let g:doxygen_ctags_extra_args = get(g:, 'doxygen_ctags_extra_args', [])
let g:doxygen_ctags_post_process_cmd = get(g:, 'doxygen_ctags_post_process_cmd', '')

let g:doxygen_ctags_exclude = get(g:, 'doxygen_ctags_exclude', [])
let g:doxygen_ctags_exclude_wildignore = get(g:, 'doxygen_ctags_exclude_wildignore', 1)

" Backwards compatibility.
function! s:_handleOldOptions() abort
    let l:renamed_options = {
                \'doxygen_exclude': 'doxygen_ctags_exclude',
                \'doxygen_tagfile': 'doxygen_ctags_tagfile',
                \'doxygen_auto_set_tags': 'doxygen_ctags_auto_set_tags'
                \}
    for key in keys(l:renamed_options)
        if exists('g:'.key)
            let newname = l:renamed_options[key]
            echom "doxygen: Option 'g:'".key." has been renamed to ".
                        \"'g:'".newname." Please update your vimrc."
            let g:[newname] = g:[key]
        endif
    endfor
endfunction
call s:_handleOldOptions()
" }}}

" doxygen Module Interface {{{

let s:did_check_exe = 0
let s:runner_exe = '"' . doxygen#get_plat_file('update_tags') . '"'
let s:unix_redir = (&shellredir =~# '%s') ? &shellredir : &shellredir . ' %s'
let s:wildignores_options_path = ''
let s:last_wildignores = ''

function! doxygen#ctags#init(project_root) abort
    " Figure out the path to the tags file.
    " Check the old name for this option, too, before falling back to the
    " globally defined name.
    let l:tagfile = getbufvar("", 'doxygen_ctags_tagfile',
                \getbufvar("", 'doxygen_tagfile', 
                \g:doxygen_ctags_tagfile))
    let b:doxygen_files['ctags'] = doxygen#get_cachefile(
                \a:project_root, l:tagfile)

    " Set the tags file for Vim to use.
    if g:doxygen_ctags_auto_set_tags
        if has('win32') || has('win64')
            execute 'setlocal tags^=' . fnameescape(b:doxygen_files['ctags'])
        else
            " spaces must be literally escaped in tags path
            let l:literal_space_escaped = substitute(fnameescape(b:doxygen_files['ctags']), '\ ', '\\\\ ', 'g')
            execute 'setlocal tags^=' . l:literal_space_escaped
        endif
    endif

    " Check if the ctags executable exists.
    if s:did_check_exe == 0
        if g:doxygen_enabled && executable(expand(g:doxygen_ctags_executable, 1)) == 0
            let g:doxygen_enabled = 0
            echoerr "Executable '".g:doxygen_ctags_executable."' can't be found. "
                        \."doxygen will be disabled. You can re-enable it by "
                        \."setting g:doxygen_enabled back to 1."
        endif
        let s:did_check_exe = 1
    endif
endfunction

function! doxygen#ctags#generate(proj_dir, tags_file, gen_opts) abort
    let l:write_mode = a:gen_opts['write_mode']

    let l:tags_file_exists = filereadable(a:tags_file)

    " If the tags file exists, we may want to do a sanity check to prevent
    " weird errors that are hard to troubleshoot.
    if l:tags_file_exists && g:doxygen_ctags_check_tagfile
        let l:first_lines = readfile(a:tags_file, '', 1)
        if len(l:first_lines) == 0 || stridx(l:first_lines[0], '!_TAG_') != 0
            call doxygen#throw(
                        \"File ".a:tags_file." doesn't appear to be ".
                        \"a ctags file. Please delete it and run ".
                        \":doxygenUpdate!.")
            return
        endif
    endif

    " Get a tags file path relative to the current directory, which 
    " happens to be the project root in this case.
    " Since the given tags file path is absolute, and since Vim won't
    " change the path if it is not inside the current directory, we
    " know that the tags file is "local" (i.e. inside the project)
    " if the path was shortened (an absolute path will always be
    " longer than a true relative path).
    let l:tags_file_relative = fnamemodify(a:tags_file, ':.')
    let l:tags_file_is_local = len(l:tags_file_relative) < len(a:tags_file)
    let l:use_tag_relative_opt = 0

    if empty(g:doxygen_cache_dir) && l:tags_file_is_local
        " If we don't use the cache directory, we can pass relative paths
        " around.
        "
        " Note that if we don't do this and pass a full path for the project
        " root, some `ctags` implementations like Exhuberant Ctags can get
        " confused if the paths have spaces -- but not if you're *in* the root 
        " directory, for some reason... (which will be the case, we're running
        " the jobs from the project root).
        let l:actual_proj_dir = '.'
        let l:actual_tags_file = l:tags_file_relative

        let l:tags_file_dir = fnamemodify(l:actual_tags_file, ':h')
        if l:tags_file_dir != '.'
            " Ok so now the tags file is stored in a subdirectory of the 
            " project root, instead of at the root. This happens if, say,
            " someone set `doxygen_ctags_tagfile` to `.git/tags`, which
            " seems to be fairly popular.
            "
            " By default, `ctags` writes paths relative to the current 
            " directory (the project root) but in this case we need it to
            " be relative to the tags file (e.g. adding `../` in front of
            " everything if the tags file is `.git/tags`).
            "
            " Thankfully most `ctags` implementations support an option
            " just for this.
            let l:use_tag_relative_opt = 1
        endif
    else
        " else: the tags file goes in a cache directory, so we need to specify
        " all the paths absolutely for `ctags` to do its job correctly.
        let l:actual_proj_dir = a:proj_dir
        let l:actual_tags_file = a:tags_file
    endif

    " Build the command line.
    let l:cmd = [s:runner_exe]
    let l:cmd += ['-e', '"' . s:get_ctags_executable(a:proj_dir) . '"']
    let l:cmd += ['-t', '"' . l:actual_tags_file . '"']
    let l:cmd += ['-p', '"' . l:actual_proj_dir . '"']
    if l:write_mode == 0 && l:tags_file_exists
        let l:cur_file_path = expand('%:p')
        if empty(g:doxygen_cache_dir) && l:tags_file_is_local
            let l:cur_file_path = fnamemodify(l:cur_file_path, ':.')
        endif
        let l:cmd += ['-s', '"' . l:cur_file_path . '"']
    else
        let l:file_list_cmd = doxygen#get_project_file_list_cmd(l:actual_proj_dir)
        if !empty(l:file_list_cmd)
            if match(l:file_list_cmd, '///') > 0
                let l:suffopts = split(l:file_list_cmd, '///')
                let l:suffoptstr = l:suffopts[1]
                let l:file_list_cmd = l:suffopts[0]
                if l:suffoptstr == 'absolute'
                    let l:cmd += ['-A']
                endif
            endif
            let l:cmd += ['-L', '"' . l:file_list_cmd. '"']
        endif
    endif
    if empty(get(l:, 'file_list_cmd', ''))
        " Pass the doxygen recursive options file before the project
        " options file, so that users can override --recursive.
        " Omit --recursive if this project uses a file list command.
        let l:cmd += ['-o', '"' . doxygen#get_res_file('ctags_recursive.options') . '"']
    endif
    if l:use_tag_relative_opt
        let l:cmd += ['-O', shellescape("--tag-relative=yes")]
    endif
    for extra_arg in g:doxygen_ctags_extra_args
        let l:cmd += ['-O', shellescape(extra_arg)]
    endfor
    if !empty(g:doxygen_ctags_post_process_cmd)
        let l:cmd += ['-P', shellescape(g:doxygen_ctags_post_process_cmd)]
    endif
    let l:proj_options_file = a:proj_dir . '/' .
                \g:doxygen_ctags_options_file
    if filereadable(l:proj_options_file)
        let l:proj_options_file = s:process_options_file(
                    \a:proj_dir, l:proj_options_file)
        let l:cmd += ['-o', '"' . l:proj_options_file . '"']
    endif
    if g:doxygen_ctags_exclude_wildignore
        call s:generate_wildignore_options()
        if !empty(s:wildignores_options_path)
            let l:cmd += ['-x', shellescape('@'.s:wildignores_options_path, 1)]
        endif
    endif
    for exc in g:doxygen_ctags_exclude
        let l:cmd += ['-x', '"' . exc . '"']
    endfor
    if g:doxygen_pause_after_update
        let l:cmd += ['-c']
    endif
    if g:doxygen_trace
        let l:cmd += ['-l', '"' . l:actual_tags_file . '.log"']
    endif
    let l:cmd = doxygen#make_args(l:cmd)

    call doxygen#trace("Running: " . string(l:cmd))
    call doxygen#trace("In:      " . getcwd())
    if !g:doxygen_fake
        let l:job_opts = doxygen#build_default_job_options('ctags')
        let l:job = doxygen#start_job(l:cmd, l:job_opts)
        call doxygen#add_job('ctags', a:tags_file, l:job)
    else
        call doxygen#trace("(fake... not actually running)")
    endif
endfunction

function! doxygen#ctags#on_job_exit(job, exit_val) abort
    let [l:tags_file, l:job_data] = doxygen#remove_job_by_data('ctags', a:job)

    if a:exit_val != 0 && !g:__doxygen_vim_is_leaving
        call doxygen#warning("ctags job failed, returned: ".
                    \string(a:exit_val))
    endif
    if has('win32') && g:__doxygen_vim_is_leaving
        " The process got interrupted because Vim is quitting.
        " Remove the tags and lock files on Windows because there's no `trap`
        " statement in update script.
        try | call delete(l:tags_file) | endtry
        try | call delete(l:tags_file.'.temp') | endtry
        try | call delete(l:tags_file.'.lock') | endtry
    endif
endfunction

" }}}

" Utilities {{{

" Get final ctags executable depending whether a filetype one is defined
function! s:get_ctags_executable(proj_dir) abort
    "Only consider the main filetype in cases like 'python.django'
    let l:ftype = get(split(&filetype, '\.'), 0, '')
    let l:proj_info = doxygen#get_project_info(a:proj_dir)
    let l:type = get(l:proj_info, 'type', l:ftype)
    let exepath = exists('g:doxygen_ctags_executable_{l:type}')
        \ ? g:doxygen_ctags_executable_{l:type} : g:doxygen_ctags_executable
    return expand(exepath, 1)
endfunction

function! s:generate_wildignore_options() abort
    if s:last_wildignores == &wildignore
        " The 'wildignore' setting didn't change since last time we did this.
        call doxygen#trace("Wildignore options file is up to date.")
        return
    endif

    if s:wildignores_options_path == ''
        if empty(g:doxygen_cache_dir)
            let s:wildignores_options_path = tempname()
        else
            let s:wildignores_options_path = 
                        \doxygen#stripslash(g:doxygen_cache_dir).
                        \'/_wildignore.options'
        endif
    endif

    call doxygen#trace("Generating wildignore options: ".s:wildignores_options_path)
    let l:opt_lines = []
    for ign in split(&wildignore, ',')
        call add(l:opt_lines, ign)
    endfor
    call writefile(l:opt_lines, s:wildignores_options_path)
    let s:last_wildignores = &wildignore
endfunction

function! s:process_options_file(proj_dir, path) abort
    if empty(g:doxygen_cache_dir)
        " If we're not using a cache directory to store tag files, we can
        " use the options file straight away.
        return a:path
    endif

    " See if we need to process the options file.
    let l:do_process = 0
    let l:proj_dir = doxygen#stripslash(a:proj_dir)
    let l:out_path = doxygen#get_cachefile(l:proj_dir, 'options')
    if !filereadable(l:out_path)
        call doxygen#trace("Processing options file '".a:path."' because ".
                    \"it hasn't been processed yet.")
        let l:do_process = 1
    elseif getftime(a:path) > getftime(l:out_path)
        call doxygen#trace("Processing options file '".a:path."' because ".
                    \"it has changed.")
        let l:do_process = 1
    endif
    if l:do_process == 0
        " Nothing's changed, return the existing processed version of the
        " options file.
        return l:out_path
    endif

    " We have to process the options file. Right now this only means capturing
    " all the 'exclude' rules, and rewrite them to make them absolute.
    "
    " This is because since `ctags` is run with absolute paths (because we
    " want the tag file to be in a cache directory), it will do its path
    " matching with absolute paths too, so the exclude rules need to be
    " absolute.
    let l:lines = readfile(a:path)
    let l:outlines = []
    for line in l:lines
        let l:exarg_idx = matchend(line, '\v^\-\-exclude=')
        if l:exarg_idx < 0
            call add(l:outlines, line)
            continue
        endif

        " Don't convert things that don't look like paths.
        let l:exarg = strpart(line, l:exarg_idx + 1)
        let l:do_convert = 1
        if l:exarg[0] == '@'   " Manifest file path
            let l:do_convert = 0
        endif
        if stridx(l:exarg, '/') < 0 && stridx(l:exarg, '\\') < 0   " Filename
            let l:do_convert = 0
        endif
        if l:do_convert == 0
            call add(l:outlines, line)
            continue
        endif

        let l:fullp = l:proj_dir . doxygen#normalizepath('/'.l:exarg)
        let l:ol = '--exclude='.l:fullp
        call add(l:outlines, l:ol)
    endfor

    call writefile(l:outlines, l:out_path)
    return l:out_path
endfunction

" }}}