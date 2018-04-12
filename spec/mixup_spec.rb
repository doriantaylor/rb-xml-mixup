RSpec.describe Mixup do
  it "has a version number" do
    expect(Mixup::VERSION).not_to be nil
  end

  class TestMixup
    include Mixup
  end

  XHTMLNS = 'http://www.w3.org/1999/xhtml'

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
end
