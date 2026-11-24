import 'package:docs_grid/features/documents/presentation/pdf_details_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main(){
  test('full name, physical path and unavailable values',(){
    expect(PdfDetailsDialog.fullName('Policy.pdf'),'Policy.pdf');
    expect(PdfDetailsDialog.fullName('Policy'),'Policy.pdf');
    expect(PdfDetailsDialog.location('file:///storage/Policy%20A.pdf',null,'Policy A'),'/storage/Policy A.pdf');
    expect(PdfDetailsDialog.location('content://pdf','Internal/Download','Policy.pdf'),'Internal/Download/Policy.pdf');
    expect(PdfDetailsDialog.sizeLabel(null),'Unavailable');
  });
  testWidgets('Phone Details shows name, size, updated and path',(tester) async {
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:Builder(builder:(ctx)=>TextButton(
      onPressed:()=>PdfDetailsDialog.showPhone(ctx,{
        'name':'Policy.pdf','uri':'content://pdf','sizeBytes':1024,
        'lastModified':'2026-11-24T08:00:00','folderPath':'Internal/Download',
      }),child:const Text('Open details'),
    )))));
    await tester.tap(find.text('Open details'));
    await tester.pumpAndSettle();
    expect(find.text('Full PDF name'),findsOneWidget);
    expect(find.text('Policy.pdf'),findsOneWidget);
    expect(find.textContaining('1.0 KB'),findsOneWidget);
    expect(find.text('Last updated'),findsOneWidget);
    expect(find.text('Internal/Download/Policy.pdf'),findsOneWidget);
  });
}
