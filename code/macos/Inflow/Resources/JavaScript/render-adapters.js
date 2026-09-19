/* Inflow's only boundary to third-party JavaScript renderers. No document scripts run here. */
(() => {
  "use strict";
  let nextID = 0;
  const escape = s => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  const modes = {js:"javascript", ts:"text/typescript", jsx:"javascript", tsx:"text/typescript", py:"python", rs:"rust", sh:"shell", bash:"shell", zsh:"shell", c:"text/x-csrc", cpp:"text/x-c++src", java:"text/x-java", cs:"text/x-csharp", html:"htmlmixed", json:"application/json", yml:"yaml", tex:"stex", latex:"stex", md:"markdown"};
  const tokenClass = style => {
    if (!style) return "";
    const first = style.split(" ")[0];
    return ({keyword:"keyword", atom:"literal", number:"number", string:"string", "string-2":"string", comment:"comment", meta:"attribute", attribute:"attribute", tag:"tag", builtin:"type", type:"type", def:"type", operator:"operator"})[first] || "";
  };
  CodeMirror.defineSimpleMode("mermaid", {start:[
    {regex:/%%.*/, token:"comment"}, {regex:/"(?:[^"\\]|\\.)*"/, token:"string"},
    {regex:/\b(?:flowchart|graph|subgraph|end|sequenceDiagram|stateDiagram-v2|classDiagram|pie|gantt|participant|actor|note|loop|alt|else|opt|par|rect|activate|deactivate|direction|style|classDef|class|click)\b/, token:"keyword"},
    {regex:/(?:-->|---|==>|-\.->|->>|-->>|<\|--)/, token:"operator"},
    {regex:/\b\d+(?:\.\d+)?\b/, token:"number"}
  ]});
  CodeMirror.defineSimpleMode("flow", {start:[
    {regex:/=>|->|\([^)]+\)/, token:"operator"},
    {regex:/\b(?:start|end|operation|condition|inputoutput|subroutine|parallel)\b/, token:"keyword"},
    {regex:/:.*/, token:"string"}
  ]});
  CodeMirror.defineSimpleMode("sequence", {start:[
    {regex:/#.*/, token:"comment"}, {regex:/\b(?:participant|Note|over|left of|right of|title)\b/, token:"keyword"},
    {regex:/(?:--?>|--?>>)/, token:"operator"}, {regex:/:.*/, token:"string"}
  ]});
  const CodeMirrorAdapter = {
    render(source, language) {
      const mode = modes[language] || (CodeMirror.findModeByName(language) || {}).mime || language;
      const tokens = [];
      const offsets = [0];
      const newline = /\r\n?|\n/g;
      let match;
      while ((match = newline.exec(source))) offsets.push(match.index + match[0].length);
      CodeMirror.runMode(source, mode, (text, style, line, column) => {
        const kind = tokenClass(style);
        if (kind && line !== undefined && column !== undefined) {
          tokens.push({start: offsets[line] + column, end: offsets[line] + column + text.length, kind});
        }
      });
      let html = "", end = 0;
      for (const token of tokens) {
        html += escape(source.slice(end, token.start)) + `<span class="tok-${token.kind}">${escape(source.slice(token.start, token.end))}</span>`;
        end = token.end;
      }
      html += escape(source.slice(end));
      return {html, tokens};
    }
  };
  const MermaidAdapter = {
    async render(source, host, id) {
      mermaid.initialize({startOnLoad:false, securityLevel:"strict", theme:"default", htmlLabels:false,
        fontFamily:"'trebuchet ms', verdana, arial, 'PingFang SC', sans-serif",
        flowchart:{htmlLabels:false, curve:"linear", useMaxWidth:false},
        secure:["securityLevel", "startOnLoad", "htmlLabels", "flowchart", "maxTextSize", "maxEdges"],
        maxTextSize:100000, maxEdges:1000});
      const result = await mermaid.render(id, source, host);
      host.innerHTML = result.svg;
    }
  };
  const FlowchartAdapter = {
    async render(source, host) {
      flowchart.parse(source).drawSVG(host, {"line-width":1.5, "font-size":16, "font-family":"Arial, PingFang SC, sans-serif", "line-color":"#333", "element-color":"#9370DB", fill:"#ECECFF", "font-color":"#333"});
    }
  };
  const SequenceAdapter = {
    async render(source, host) {
      Diagram.parse(source).drawSVG(host, {theme:"simple", "font-family":"Arial, PingFang SC, sans-serif"});
      // Snap's font-ready callback can complete after drawSVG returns.
      const deadline = performance.now() + 5000;
      while (!host.querySelector("svg")) {
        if (performance.now() > deadline) throw Error("Sequence rendering timed out");
        await new Promise(resolve => setTimeout(resolve, 16));
      }
    }
  };
  const MathJaxAdapter = {
    async render(source, host, id, display) {
      await MathJax.startup.promise;
      MathJax.texReset();
      const node = await MathJax.tex2svgPromise(source, {display, em:16, ex:8, containerWidth:760});
      if (node.querySelector("[data-mjx-error]")) throw Error("Invalid TeX");
      host.append(node);
    }
  };
  function standaloneSVG(host, kind) {
    const svg = host.querySelector("svg");
    if (!svg || svg.querySelector("foreignObject")) throw Error("Renderer did not produce a standalone SVG");
    // Raphael reuses marker definitions from earlier diagrams. Copy them into this SVG
    // before detaching it so every result remains independent of the live document.
    for (const use of svg.querySelectorAll("use")) {
      const href = use.getAttribute("href") || use.getAttributeNS("http://www.w3.org/1999/xlink", "href") || "";
      const id = href.split("#")[1];
      if (!id || [...svg.querySelectorAll("[id]")].some(node => node.id === id)) continue;
      const definition = document.getElementById(id);
      if (definition) (svg.querySelector("defs") || svg).append(definition.cloneNode(true));
    }
    // Resolve CSS while the SVG is mounted. AppKit's decoder does not implement CSS selectors.
    const properties = ["fill", "fill-opacity", "stroke", "stroke-width", "stroke-opacity", "stroke-dasharray", "stroke-linecap", "stroke-linejoin", "font-family", "font-size", "font-weight", "font-style", "text-anchor", "dominant-baseline", "opacity", "marker-start", "marker-mid", "marker-end"];
    for (const node of [svg, ...svg.querySelectorAll("*")]) {
      if (["style", "script", "foreignObject", "image", "animate", "set"].includes(node.localName)) continue;
      const style = getComputedStyle(node);
      for (const property of properties) {
        let value = style.getPropertyValue(property);
        // WebKit expands local paint references to absolute document URLs.
        value = value.replace(/url\(["']?[^)#]*#([^)'" ]+)["']?\)/g, "url(#$1)");
        if (value) node.setAttribute(property, value);
      }
    }
    // Inline Raphael's marker <use>: WebKit PDF can omit referenced marker geometry.
    for (const use of svg.querySelectorAll("marker use")) {
      const href = use.getAttribute("href") || use.getAttributeNS("http://www.w3.org/1999/xlink", "href") || "";
      const target = [...svg.querySelectorAll("[id]")].find(node => node.id === href.split("#")[1]);
      if (!target) continue;
      const shape = target.cloneNode(true);
      shape.removeAttribute("id");
      for (const attr of use.attributes) if (!attr.name.includes("href")) shape.setAttribute(attr.name, attr.value);
      use.replaceWith(shape);
    }
    // AppKit ignores tspan dy offsets. Preserve actual browser-measured line positions.
    for (const text of [...svg.querySelectorAll("text")]) {
      const spans = [...text.querySelectorAll("tspan")].filter(span => !span.querySelector("tspan") && span.textContent);
      if (!spans.length) continue;
      const group = document.createElementNS(svg.namespaceURI, "g");
      if (text.hasAttribute("transform")) group.setAttribute("transform", text.getAttribute("transform"));
      for (const span of spans) {
        const line = document.createElementNS(svg.namespaceURI, "text");
        for (const name of properties) if (span.hasAttribute(name)) line.setAttribute(name, span.getAttribute(name));
        const p = span.getStartPositionOfChar(0);
        line.setAttribute("x", p.x); line.setAttribute("y", p.y);
        line.setAttribute("text-anchor", "start");
        line.textContent = span.textContent;
        group.append(line);
      }
      text.replaceWith(group);
    }
    const rect = svg.getBoundingClientRect();
    const box = svg.viewBox.baseVal;
    const width = rect.width || box.width, height = rect.height || box.height;
    if (![width, height].every(n => Number.isFinite(n) && n > 0 && n <= 16384)) throw Error("Invalid SVG size");
    if (!svg.hasAttribute("viewBox")) svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    svg.setAttribute("xmlns", "http://www.w3.org/2000/svg");
    svg.setAttribute("width", width); svg.setAttribute("height", height);
    for (const node of [...svg.querySelectorAll("script,style,foreignObject,image,animate,animateMotion,animateTransform,set,iframe")]) node.remove();
    for (const node of [svg, ...svg.querySelectorAll("*")]) {
      for (const attr of [...node.attributes]) {
        const name = attr.name.toLowerCase();
        if ((name === "href" || name === "xlink:href") && attr.value.includes("#")) {
          const target = new URL(attr.value, document.baseURI);
          const current = new URL(document.baseURI);
          if (target.origin === current.origin && target.pathname === current.pathname) attr.value = target.hash;
        }
        if (name.startsWith("on") || name === "style" || ((name === "href" || name === "xlink:href") && !attr.value.startsWith("#"))) node.removeAttribute(attr.name);
      }
    }
    if (kind !== "math") {
      const background = document.createElementNS(svg.namespaceURI, "rect");
      const bounds = svg.viewBox.baseVal;
      background.setAttribute("x", bounds.x); background.setAttribute("y", bounds.y);
      background.setAttribute("width", bounds.width); background.setAttribute("height", bounds.height);
      background.setAttribute("fill", "#ffffff");
      svg.prepend(background);
    }
    return {svg:new XMLSerializer().serializeToString(svg), width:Math.ceil(width), height:Math.ceil(height)};
  }
  const adapters = {mermaid:MermaidAdapter, flow:FlowchartAdapter, sequence:SequenceAdapter, math:MathJaxAdapter};
  async function render(request) {
    if (request.source.length > 100000) throw Error("Render input too large");
    if (request.kind === "code") return CodeMirrorAdapter.render(request.source, request.language.toLowerCase());
    const adapter = adapters[request.kind];
    if (!adapter) throw Error("Unknown renderer");
    const host = document.createElement("div");
    host.id = "inflow-host-" + (++nextID);
    host.style.cssText = "display:table;color:#333;font-size:16px;background:white";
    document.body.append(host);
    try {
      await adapter.render(request.source, host, "inflow-svg-" + nextID, !!request.display);
      return standaloneSVG(host, request.kind);
    } finally { host.remove(); }
  }
  async function renderDocument() {
    for (const element of [...document.querySelectorAll("[data-inflow-render]")]) {
      const kind = element.dataset.inflowRender;
      const source = element.textContent;
      try {
        const result = await render({kind, source, language:element.dataset.language || kind, display:element.dataset.display === "true"});
        element.innerHTML = result.svg || result.html;
        element.removeAttribute("data-inflow-render");
      } catch (_) {
        element.setAttribute("data-inflow-render-error", "true");
        element.setAttribute("title", "无法渲染，原内容已保留");
      }
    }
  }
  window.InflowRender = {render, renderDocument, CodeMirrorAdapter};
})();
