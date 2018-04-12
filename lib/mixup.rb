require 'mixup/version'
require 'nokogiri'

module Mixup

  # these are node attachment protocols
  ADJACENT = {
              parent:  lambda do |node, parent|
                if parent.node_type == 9 and node.node_type == 1
                  parent.root = node
                elsif node.node_type == 11
                  node.children.each do |child|
                    parent.add_child child
                  end
                else
                  parent.add_child node
                end
              end,
              before:  lambda do |node, sibling|
                sibling.add_previous_sibling node
              end,
              after:   lambda { |node, sibling| sibling.add_next_sibling node },
              replace: lambda { |node, target|  target.replace node },
             }

  def xml_doc version = nil
    Nokogiri::XML::Document.new version
  end

  def markup spec: nil, args: [], **nodes
    # handle adjacent node declaration
    adj = nil
    ADJACENT.keys do |k|
      if nodes[k]
        if adj
          raise
        end
        unless nodes[k].is_a? Nokogiri::XML::Node
          raise
        end
        adj = k
      end
    end

    # generate doc/parent
    if adj
      nodes[:doc] ||= nodes[adj].document
      unless adj == 'parent'
        unless (nodes[:parent] = nodes[adj].parent)
          raise
        end
      end
    else
      nodes[:doc] ||= Nokogiri::XML::Document.new
      nodes[adj = :parent] ||= nodes[:doc] 
    end

    # dispatch based on spec type
    doc  = nodes[:doc]
    node = nodes[adj]

    #warn nodes.inspect

    if spec
      if spec.is_a? Array
        par = adj == 'parent' ? nodes[:parent] : doc.fragment
        out = spec.map do |x|
          markup(spec: x, parent: par, pseudo: nodes[:parent], doc: doc,
                 args: nodes[:args])
        end

        # only run this if there is something to run
        if out.length > 0
          # this is already attached if the adjacent node is the parent
          ADJACENT[adj].call(par, nodes[adj]) unless adj == 'parent'
          node = out.last
        end
        # node otherwise defaults to adjacent

      elsif spec.respond_to? :call
        # handle proc/lambda/whatever
        node = markup(spec: spec.call(*args), args: args,
                      doc: nodes[:doc], adj => nodes[adj])
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
        end

        # note the name can be nil because it can be inferred

        # now we pull out "attributes" which are the rest of the keys;
        # these should be amenable to being turned into symbols
        attr = spec.select { |k, _|
          k and k.respond_to? :to_sym }.transform_keys(&:to_sym)

        # now we dispatch based on the name
        if name == '#comment'
          # first up, comments
          node = doc.create_comment flatten(children, args)

          # attach it
          ADJACENT[adj].call node, nodes[adj]

        elsif name == '#pi' or name == '#processing-instruction'
          # now processing instructions
          if children.empty?
            raise
          end
          target  = children[0]
          content = ''
          if (c = children[1..children.length]) and c.length > 0
            #warn c.inspect
            content = flatten(c, args)
          else
            content = attr.sort.map { |pair|
              "#{pair[0].to_s}=\"#{flatten(pair[1], args)}\""
            }.join(' ')
          end
              
          node = Nokogiri::XML::ProcessingInstruction.new(doc, target, content)

          #warn node.inspect, content

          # attach it
          ADJACENT[adj].call node, nodes[adj]

        elsif name == '#dtd' or name == '#doctype'
          # now doctype declarations
          if children.empty?
            raise
          end

          # assign as if these are args
          root, pub, sys = children
          # supplant with attributes if present
          pub ||= attr[:public] if attr[:public]
          sys ||= attr[:system] if attr[:system]

          # XXX for some reason this is an *internal* subset?
          node = doc.create_internal_subset(root, pub, sys)

          # at any rate it doesn't have to be explicitly attached

          # attach it to the document
          #doc.add_child node

          # attach it (?)
          #ADJACENT[adj].call node, nodes[adj]

        else
          # finally, an element

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
            v = flatten(v, args)
            if (md = /^xmlns(?::(.*))?$/i.match(k.to_s))
              ns[md[1]] = v
            else
              at[k.to_s] = v
            end
          end

          # now go over the attributes and set any missing namespaces to nil
          at.keys.each do |k|
            p, _ = /^(?:([^:]+):)?(.+)$/.match(k).captures
            ns[p] ||= nil
          end
          # also do the tag prefix but only if there is a local name
          ns[prefix] ||= nil if local

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
            raise
          end

          # generate the node
          node = element name, doc: doc, ns: ns, attr: at

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
          node = spec.dup
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

  private

  def element tag, doc: nil, ns: {}, attr: {}
    raise unless doc
    prefix = local = nil
    if tag.respond_to? :to_a
      prefix, local = tag
      tag = tag.join ':'
    end
    elem = doc.create_element tag.to_s
    ns.each do |p, u|
      elem.add_namespace p, u
    end
    attr.each do |k, v|
      elem[k] = v
    end

    elem
  end

  def flatten obj, args
    if obj.is_a? Hash
      obj.sort.map { |kv| "#{kv[0].to_s}: #{flatten(kv[1], args)}" }.join(' ')
    elsif obj.respond_to? :call
      obj.call(*args)
    elsif obj.respond_to? :map
      obj.map { |x| flatten(x, args) }.join(' ')
    elsif obj.nil?
      ''
    else
      obj.to_s
    end
  end

end
