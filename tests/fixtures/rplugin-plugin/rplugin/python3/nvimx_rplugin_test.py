import pynvim


@pynvim.plugin
class NvimxRpluginTest(object):
    def __init__(self, nvim):
        self.nvim = nvim

    @pynvim.function("NvimxRpluginTest", sync=True)
    def test(self, args):
        return "@version@"

    @pynvim.command("NvimxRpluginCmd", sync=True)
    def cmd(self):
        self.nvim.vars["nvimx_rplugin_cmd"] = "@version@"

    @pynvim.autocmd("User", pattern="NvimxRpluginPing", sync=True)
    def ping(self):
        pings = self.nvim.vars.get("nvimx_rplugin_ping", [])
        self.nvim.vars["nvimx_rplugin_ping"] = list(pings) + ["@version@"]
