# Safe Action Debugger

Interactive debugger for GitHub Actions. The connection information can sent to you via Telegram Bot. It also supports attaching docker image/container.

## Usage

```yml
    steps:
    - name: SSH远程连接
      uses: datout/debugger-action@main
```

## Acknowledgments

* P3TERX's [debugger-action](https://github.com/P3TERX/debugger-action)
* [tmate.io](https://tmate.io)
* Max Schmitt's [action-tmate](https://github.com/mxschmitt/action-tmate)
* Christopher Sexton's [debugger-action](https://github.com/csexton/debugger-action)

### License

The action and associated scripts and documentation in this project are released under the MIT License.
