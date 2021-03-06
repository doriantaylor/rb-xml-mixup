RSpec.describe XML::Mixup do
  it "has a version number" do
    expect(XML::Mixup::VERSION).not_to be nil
  end

  class TestMixup
    include XML::Mixup
  end

  XHTMLNS = 'http://www.w3.org/1999/xhtml'
  SVGNS   = 'http://www.w3.org/2000/svg'

  obj = TestMixup.new

  it "has a `markup` method" do
    expect(obj.respond_to? :markup)
  end

  it "empty call to `markup` method returns an XML doc" do
    doc = obj.markup
    expect(doc).to be_a Nokogiri::XML::Document
  end

  it "markup with a hash makes an element" do
    node = obj.markup spec: { nil => :foo }
    expect(node).to be_a Nokogiri::XML::Element
    expect(node.name).to eq('foo')
  end

  it "subsequent content makes child nodes" do
    node = obj.markup spec: { nil => [:foo, 'hi'] }
    expect(node).to be_a Nokogiri::XML::Text
    expect(node.parent).to be_a Nokogiri::XML::Element
  end

  it "sets an appropriate namespace" do
    node = obj.markup spec: { nil => :html, xmlns: XHTMLNS }
    expect(node.name).to eq('html')
    expect(node.namespace).to be_a Nokogiri::XML::Namespace
    expect(node.namespace.href).to eq(XHTMLNS)

    obj.markup spec: [{ nil => [:head, { nil => [:title, 'yo dawg'] } ] },
                      { nil => [:body, { nil => [:h1, 'i said yo dawg'] } ] }],
      parent: node

    expect(node.xpath('count(//node())')).to eq(7)

    node = obj.markup spec: { nil => 'svg:svg', 'xmlns:svg' => SVGNS }
    expect(node.namespace).to be_a Nokogiri::XML::Namespace
    expect(node.namespace.href).to eq(SVGNS)
  end

  it "can set a DTD" do
    node = obj.markup spec: [{ nil => ["#dtd", 'html']}, { nil => :html }]
    expect(node.document.children[0]).to be_a Nokogiri::XML::DTD
    expect(node.document.children[0].name).to eq('html')
  end

  it "can set a processing instruction" do
    node = obj.markup spec: [{ nil => ['#pi', 'xml-stylesheet'],
                              type: 'text/xsl', href: '/transform' },
                             { nil => :html, xmlns: XHTMLNS }]
    #warn node.document
  end

  it "can take the compact syntax" do
    node = obj.markup spec: { ['hi'] => :foo, xmlns: 'urn:x-dummy' }
    expect(node.to_s).to eq('hi')
    # warn node.document
    expect(node.parent.name).to eq('foo')
    expect(node.parent.namespace.href).to eq('urn:x-dummy')
  end

  it "can take the `#foo` compact syntax" do
    node = obj.markup spec: [{ '#pi' => 'xml-stylesheet', type: 'text/xsl',
                              href: '/transform' },
                             { '#dtd' => 'html' },
                             { '#html' =>
                              [{ '#head' =>
                                 [{ '#title' => 'hi' },
                                  { '#tag' => 'base', href: 'http://foo.bar/' },
                                 ]},
                               { '#body' => :lol,
                                typeof: 'foaf:Document' } ],
                            xmlns: XHTMLNS,
                             },
                            ]
    # warn node.document
    expect(node.to_s).to eq 'lol'
  end

  it "can replace a node like it says in the docs" do
    node = obj.markup spec: { [{ nil => :bar }] => :foo }
    doc  = node.document

    node2 = obj.markup replace: node, spec: { nil => :lol }

    expect(doc.root.first_element_child.name).to eq 'lol'
    
  end

  it "handles the transform parameter correctly" do
    doc = obj.xhtml_stub(transform: '/transform').document
    expect(doc.at_xpath(
      "processing-instruction('xml-stylesheet')")).not_to be_nil
  end

  it "knows what to do with eg xml:lang" do
    node = obj.markup spec: {
      nil => :foo, xmlns: 'http://www.w3.org/1999/xhtml', 'xml:lang' => :en }
    expect(node['xml:lang']).to eq 'en'
    #warn node.to_s
  end

  it "omits attributes when their supplied values are nil" do
    node = obj.markup spec: {
      nil => :foo, xmlns: 'http://www.w3.org/1999/xhtml',
      test0: '', test1: nil, test2: [], test3: Proc.new { nil },
      test4: { hi: :there, lol: nil },
      test5: ['empty', '', 'strings']
    }
    #warn node.to_s
    expect(node.key? 'test0').to be true
    expect(node.key? 'test1').to be false
    expect(node.key? 'test2').to be false
    expect(node.key? 'test3').to be false
    expect(node.key? 'test4').to be true
    expect(node['test4']).to eq 'hi: there'
    expect(node['test5']).to eq 'empty strings'
  end
end
