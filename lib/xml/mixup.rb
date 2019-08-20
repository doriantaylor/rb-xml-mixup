require 'xml/mixup/version'
require 'nokogiri'
require 'set'

module XML::Mixup

  # 

  # these are node attachment protocols
  private
  
  ADJACENT = {
    parent:  lambda do |node, parent|
      if parent.node_type == 9 and node.node_type == 1
        parent.root = node
      elsif node.node_type == 11
        node.children.each do |child|
          parent.add_child(child)
        end
      else
        parent.add_child(node)
      end
    end,
    before:  lambda do |node, sibling|
      sibling.add_previous_sibling node
    end,
    after:   lambda { |node, sibling| sibling.add_next_sibling node },
    replace: lambda { |node, target| target.replace node },
  }.freeze

  RESERVED = Set.new(%w{comment cdata doctype dtd elem element
    pi processing-instruction tag}.map {|x| "##{x}"}).freeze

  public

  # Generate a handy blank document.
  #
  # @param version [Numeric, nil]
  #
  # @return [Nokogiri::XML::Document] a Nokogiri XML document.

  def xml_doc version = nil
    Nokogiri::XML::Document.new version
  end

  # Generates an XML tree from a given specification.
  #
  #  require 'xml-mixup'
  #
  #  class Anything
  #    include XML::Mixup
  #  end
  #
  #  something = Anything.new
  #
  #  # generate a structure
  #  node = something.markup spec: [
  #    { '#pi'   => 'xml-stylesheet', type: 'text/xsl', href: '/transform' },
  #    { '#dtd'  => :html },
  #    { '#html' => [
  #      { '#head' => [
  #        { '#title' => 'look ma, title' },
  #        { '#elem'  => :base, href: 'http://the.base/url' },
  #      ] },
  #      { '#body' => [
  #        { '#h1' => 'Illustrious Heading' },
  #        { '#p'  => :lolwut },
  #      ] },
  #    ], xmlns: 'http://www.w3.org/1999/xhtml' }
  #  ]
  #
  #  # `node` will correspond to the last thing generated. In this
  #  # case, it will be a text node containing 'lolwut'.
  #
  #  doc = node.document
  #  puts doc.to_xml  
  #
  # @param spec [Hash, Array, Nokogiri::XML::Node, Proc, #to_s] An XML
  #  tree specification. May be composed of multiple hashes and
  #  arrays. See the spec spec.
  # 
  # @param doc [Nokogiri::XML::Document, nil] an optional XML document
  #  instance; will be supplied if none given.
  #
  # @param args [#to_a] Any arguments to be passed to any callbacks
  #  anywhere in the spec. Assumed to be an array.
  # 
  # @param parent [Nokogiri::XML::Node] The node under which the
  #  evaluation result of the spec is to be attached. This is the
  #  default adjacent node, which in turn defaults to the document if
  #  it or no other adjacent node is given. Conflicts with other
  #  adjacent nodes.
  #
  # @param before [Nokogiri::XML::Node] This represents a _sibling_
  #  node which the spec is to be inserted _before_. Conflicts with
  #  other adjacent nodes.
  #
  # @param after [Nokogiri::XML::Node] This represents a _sibling_
  #  node which the spec is to be inserted _after_. Conflicts with
  #  other adjacent nodes.
  #
  # @param replace [Nokogiri::XML::Node] This represents a _sibling_
  #  node which the spec is intended to _replace_. Conflicts with
  #  other adjacent nodes.
  #
  # @return [Nokogiri::XML::Node] the last node generated, in document
  #  order. Will return a {Nokogiri::XML::Document} when called
  #  without arguments.

  def markup spec: nil, doc: nil, args: [], **nodes
    # handle adjacent node declaration
    adj = nil
    ADJACENT.keys.each do |k|
      if nodes[k]
        if adj
          raise "Cannot bind to #{k}: #{adj} is already present"
        end
        unless nodes[k].is_a? Nokogiri::XML::Node
          raise "#{k} must be an XML node"
        end
        adj = k
      end
    end

    # generate doc/parent
    if adj
      doc ||= nodes[adj].document
      unless adj.to_sym == :parent
        unless (nodes[:parent] = nodes[adj].parent)
          raise "#{adj} node must have a parent node!"
        end
      end
    else
      doc ||= Nokogiri::XML::Document.new
      nodes[adj = :parent] ||= doc
    end

    node = nodes[adj]

    # dispatch based on spec type
    if spec and not (spec.respond_to? :empty? and spec.empty?)
      spec = spec.to_a if spec.is_a? Nokogiri::XML::NodeSet
      if spec.is_a? Array
        par = adj == :parent ? nodes[:parent] : doc.fragment
        out = spec.map do |x|
          markup(spec: x, parent: par, pseudo: nodes[:parent], doc: doc,
                 args: nodes[:args])
        end

        # only run this if there is something to run
        if out.length > 0
          # this is already attached if the adjacent node is the parent
          ADJACENT[adj].call(par, nodes[adj]) unless adj == :parent
          node = out.last
        end
        # node otherwise defaults to adjacent

      elsif spec.respond_to? :call
        # handle proc/lambda/whatever
        node = markup(spec: spec.call(*args), args: args,
                      doc: doc, adj => nodes[adj])
      elsif spec.is_a? Hash
        # maybe element, maybe something else

        # find the nil key which should contain a viable node name
        # (and maybe children)
        name     = nil
        children = []
        if x = spec[nil]
          if x.respond_to? :to_a
            x = x.to_a
            name = x.shift
            children = x
          else 
            name = x
          end
        elsif (compact = spec.select { |k, _| k.respond_to?(:to_a) or
                   k.is_a?(Nokogiri::XML::Node)}) and !compact.empty?
          # compact syntax eliminates the `nil` key
          raise %q{Spec can't have duplicate compact keys} if compact.count > 1
          children, name = compact.first
          children = children.is_a?(Hash) ||
            children.is_a?(Nokogiri::XML::Node) ? [children] : children.to_a 
        elsif (special = spec.select { |k, _| k.respond_to? :to_s and
                   k.to_s.start_with? ?# }) and !special.empty?
          # these are special keys 
          raise %q{Spec can't have multiple special keys} if special.count > 1
          name, children = special.first

          if %w{# #elem #element #tag}.include? name
            # then the name is in the `children` slot
            raise "Value of #{name} shorthand formulation" +
              "must be a valid element name" unless children.respond_to? :to_s
            name = children
            # set children to empty array
            children = []
          elsif not RESERVED.any? name
            # then the name is encoded into the key and we have to
            # remove the octothorpe
            name = name.delete_prefix ?#
            # note we assign because the object is input and may be frozen
          end

          # don't forget to reset the child nodes
          children = children.is_a?(Hash) || !children.respond_to?(:to_a) ?
            [children] : children.to_a 
        end

        # note the name can be nil because it can be inferred

        # now we pull out "attributes" which are the rest of the keys;
        # these should be amenable to being turned into symbols
        attr = spec.select { |k, _|
          k and k.respond_to? :to_sym and not k.to_s.start_with? '#'
        }.transform_keys(&:to_sym)

        # now we dispatch based on the name
        if name == '#comment'
          # first up, comments
          node = doc.create_comment flatten(children, args).to_s

          # attach it
          ADJACENT[adj].call node, nodes[adj]

        elsif name == '#pi' or name == '#processing-instruction'
          # now processing instructions
          if children.empty?
            raise "Processing instruction must have at least a target"
          end
          target  = children[0]
          content = ''
          if (c = children[1..children.length]) and c.length > 0
            #warn c.inspect
            content = flatten(c, args).to_s
          else
            content = attr.sort.map { |pair|
              v = flatten(pair[1], args) or next
              "#{pair[0].to_s}=\"#{v}\""
            }.compact.join(' ')
          end
              
          node = Nokogiri::XML::ProcessingInstruction.new(doc, target, content)

          #warn node.inspect, content

          # attach it
          ADJACENT[adj].call node, nodes[adj]

        elsif %w[#dtd doctype].include? name
          # now doctype declarations
          if children.empty?
            raise "DTD node must have a root element declaration"
          end

          # assign as if these are args
          root, pub, sys = children
          # supplant with attributes if present
          pub ||= attr[:public] if attr[:public]
          sys ||= attr[:system] if attr[:system]

          # XXX for some reason this is an *internal* subset?
          # anyway these may not be strings and upstream is not forgiving
          node = doc.create_internal_subset(root.to_s,
                                            pub.nil? ? pub : pub.to_s,
                                            sys.nil? ? sys : sys.to_s)


          # at any rate it doesn't have to be explicitly attached

          # attach it to the document
          #doc.add_child node

          # attach it (?)
          #ADJACENT[adj].call node, nodes[adj]
        elsif name == '#cdata'
          # let's not forget cdata sections
          node = doc.create_cdata flatten(children, args)
          # attach it
          ADJACENT[adj].call node, nodes[adj]

        else
          # finally, an element

          raise 'Element name inference NOT IMPLEMENTED' unless name

          # first check the name
          prefix = local = nil
          if name and (md = /^(?:([^:]+):)?(.+)/.match(name.to_s))
            # XXX match actual qname/ncname here
            prefix, local = md.captures
          end

          # next pull apart the namespaces and ordinary attributes
          ns = {}
          at = {}
          attr.each do |k, v|
            k = k.to_s
            v = flatten(v, args) or next
            if (md = /^xmlns(?::(.*))?$/i.match(k))
              ns[md[1]] = v
            else
              at[k] = v
            end
          end

          # now go over the attributes and set any missing namespaces to nil
          at.keys.each do |k|
            p, _ = /^(?:([^:]+):)?(.+)$/.match(k).captures
            ns[p] ||= nil
          end

          # also do the tag prefix but only if there is a local name
          ns[prefix] ||= nil if local

          # unconditionally remove ns['xml'], we never want it in there
          ns.delete 'xml'

          # pseudo is a stand-in for non-parent adjacent nodes
          pseudo = nodes[:pseudo] || nodes[:parent]

          # now get the final namespace mapping
          ns.keys.each do |k|
            pk = k ? "xmlns:#{k}" : "xmlns"
            if pseudo.namespaces.has_key? pk
              ns[k] ||= pseudo.namespaces[pk]
            end
          end
          # delete nil => nil
          if ns.has_key? nil and ns[nil].nil?
            ns.delete(nil)
          end

          # there should be no nil namespace declarations now
          if ns.has_value? nil
            raise "INTERNAL ERROR: nil namespace declaration: #{ns}"
          end

          # generate the node
          node = element name, doc: doc, ns: ns, attr: at, args: args

          # attach it 
          ADJACENT[adj].call node, nodes[adj]

          # don't forget the children!
          if children.length > 0
            #warn node.inspect, children.inspect
            node = markup(spec: children, doc: doc, parent: node, args: args)
          end
        end
      else
        if spec.is_a? Nokogiri::XML::Node
          # existing node
          node = spec.dup 1
        else
          # text node
          node = doc.create_text_node spec.to_s
        end

        # attach it
        ADJACENT[adj].call node, nodes[adj]
      end
    end

    # return the node
    node
  end

  # Generates an XHTML stub, with optional RDFa attributes. All
  # parameters are optional.
  #
  # *This method is still under development.* I am still trying to
  # figure out how I want it to behave. Some parts may not work as
  # advertised.
  #
  # @param doc [Nokogiri::XML::Document, nil] an optional document.
  #
  # @param base [#to_s] the contents of +<base href=""/>+.
  #
  # @param prefix [Hash] the contents of the root node's +prefix=+
  #  and +xmlns:*+ attributes.
  # 
  # @param vocab [#to_s] the contents of the root node's +vocab=+.
  #
  # @param lang [#to_s] the contents of +lang=+ and when applicable,
  #  +xml:lang+.
  #
  # @param title [#to_s, #to_a, Hash] the contents of the +<title>+
  #  tag. When given as an array-like object, all elements after the
  #  first one will be flattened to a single string and inserted into
  #  the +property=+ attribute. When given as a {Hash}, it will be
  #  coerced into a snippet of spec that produces the appropriate tag.
  #
  # @param link [#to_a, Hash] A spec describing one or more +<link/>+
  #  elements.
  #
  # @param meta [#to_a, Hash] A spec describing one or more +<meta/>+
  #  elements.
  #
  # @param style [#to_a, Hash] A spec describing one or more
  #  +<style/>+ elements.
  #
  # @param script [#to_a, Hash] A spec describing one or more
  #  +<script/>+ elements.
  #
  # @param extra [#to_a, Hash] A spec describing any extra elements
  #  inside +<head>+ that aren't in the previous categories.
  #
  # @param attr [Hash] A spec containing attributes for the +<body>+.
  #
  # @param content [Hash, Array, Nokogiri::XML::Node, ...] A spec which
  #  will be attached underneath the +<body>+.
  #
  # @param head [Hash, Array] A Hash spec which overrides the entire
  #  +<head>+ element, or otherwise an array of its children.
  #
  # @param body [Hash] A spec which overrides the entire +<body>+.
  #
  # @param transform [#to_s] An optional XSLT transform.
  #
  # @param dtd [true, false, nil, #to_a] Whether or not to attach a
  #  +<!DOCTYPE html>+ declaration. Can be given as an array-like
  #  thing containing two stringlike things which serve as public and
  #  system identifiers. Defaults to +true+.
  #
  # @param xmlns [true, false, nil, Hash] Whether or not to include
  #  XML namespace declarations, including the XHTML declaration. When
  #  given as a {Hash}, it will set _only the hash contents_ as
  #  namespaces. Defaults to +true+.
  #
  # @param args [#to_a] Arguments for any callbacks in the spec.
  # 
  # @return [Nokogiri::XML::Node] the last node generated, in document order.

  def xhtml_stub doc: nil, base: nil, ns: {}, prefix: {}, vocab: nil,
      lang: nil, title: nil, link: [], meta: [], style: [], script: [],
      extra: [], head: {}, body: {}, attr: {}, content: [],
      transform: nil, dtd: true, xmlns: true, args: []

    spec = []

    # add xslt stylesheet
    if transform
      spec << (transform.is_a?(Hash) ? transform :
        { '#pi' => 'xml-stylesheet', type: 'text/xsl', href: transform })
    end

    # add doctype declaration
    if dtd
      ps = dtd.respond_to?(:to_a) ? dtd.to_a : []
      spec << { nil => %w{#dtd html} + ps }
    end

    # normalize title

    if title.nil? or (title.respond_to?(:empty?) and title.empty?)
      title = { '#title' => '' } # add an empty string for closing tag
    elsif title.is_a? Hash
      # nothing
    elsif title.respond_to? :to_a
      title = title.to_a
      text  = title.shift
      props = title
      title = { '#title' => text }
      title[:property] = props unless props.empty?
    else
      title = { '#title' => title }
    end

    # normalize base

    if base and not base.is_a? Hash
      base = { nil => :base, href: base }
    end

    # TODO normalize link, meta, style, script elements

    # construct document tree

    head ||= {}
    if head.is_a? Hash and head.empty? 
      head[nil] = [:head, title, base, link, meta, style, script, extra]
    elsif head.is_a? Array
      # children of unmarked head element
      head = { nil => [:head] + head }
    end

    body ||= {}
    if body.is_a? Hash and body.empty?
      body[nil] = [:body, content]
      body = attr.merge(body) if attr and attr.is_a?(Hash)
    end

    root = { nil => [:html, head, body] }
    root[:vocab] = vocab if vocab
    root[:lang]  = lang  if lang

    # deal with namespaces
    if xmlns
      root['xmlns'] = 'http://www.w3.org/1999/xhtml'

      # namespaced language attribute
      root['xml:lang'] = lang if lang

      if !prefix and xmlns.is_a? Hash
        x = prefix.transform_keys { |k| "xmlns:#{k}" }
        root = x.merge(root)
      end
    end

    # deal with prefixes distinct from namespaces
    prefix ||= {}
    if prefix.respond_to? :to_h
      prefix = prefix.to_h
      unless prefix.empty?
        # this will get automatically smushed into the right shape
        root[:prefix] = prefix

        if xmlns
          x = prefix.transform_keys { |k| "xmlns:#{k}" }
          root = x.merge(root)
        end
      end
    end

    # add the document structure to the spec
    spec << root

    # as usual this will return the last innermost node
    markup spec: spec, doc: doc, args: args
  end

  private

  def element tag, doc: nil, ns: {}, attr: {}, args: []
    raise 'Document node must be present' unless doc
    pfx = nil
    if tag.respond_to? :to_a
      pfx = tag[0]
      tag = tag.to_a[0..1].join ':'
    elsif m = tag.match(/([^:]+):/)
      pfx = m[1]
    end

    elem = doc.create_element tag.to_s
    elem.default_namespace = ns[pfx] if ns[pfx]

    ns.keys.sort { |a, b| a.to_s <=> b.to_s }.each do |p|
      elem.add_namespace((p.nil? ? p : p.to_s), ns[p].to_s)
    end
    attr.sort.each do |k, v|
      v = flatten(v, args) or next
      elem[k.to_s] = v
    end

    elem
  end

  ATOMS = [String, Symbol, Numeric, FalseClass, TrueClass].freeze

  # yo dawg

  def flatten obj, args
    return if obj.nil?
    # early bailout for most likely condition
    if ATOMS.any? { |x| obj.is_a? x }
      obj.to_s
    elsif obj.is_a? Hash
      tmp = obj.sort.map do |kv|
        v = flatten(kv[1], args)
        v.nil? ? nil : "#{kv[0].to_s}: #{v}"
      end.compact
      tmp.empty? ? nil : tmp.join(' ')
    elsif obj.respond_to? :call
      flatten(obj.call(*args), args)
    elsif obj.respond_to? :map
      tmp = obj.map { |x| flatten(x, args) }.reject { |x| x.nil? || x == '' }
      tmp.empty? ? nil : tmp.join(' ')
    else
      obj.to_s
    end
  end

end
