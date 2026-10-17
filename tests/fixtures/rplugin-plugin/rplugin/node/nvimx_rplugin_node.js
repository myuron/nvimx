module.exports = (plugin) => {
  plugin.registerFunction("NvimxRpluginNode", () => "node", { sync: true });
};
